import AVFoundation
import Foundation

/// Bounded handoff from the audio tap to one serial file writer.
///
/// The tap callback runs on an AVFoundation worker thread, where allocating, blocking on a
/// mutex or touching the filesystem risks a dropout. So every destination is preallocated:
/// `enqueue` takes a slab permit without blocking, memcpys into memory that already exists,
/// and wakes one serial writer. When no permit is free the buffer is refused and the caller
/// turns that into a thrown error; a recording that lost audio must fail rather than arrive
/// silently short.
///
/// Ported from `references/pindrop/Pindrop/Services/AudioRecorder.swift:459-712`, without that
/// project's byte cap, second native-rate spool or writer-delay test seam.
final class AudioSpool: @unchecked Sendable {
    enum Failure: Error, LocalizedError {
        case temporaryFileUnavailable(String)
        case writeFailed(String)
        case notSpooling

        var errorDescription: String? {
            switch self {
            case .temporaryFileUnavailable(let reason):
                return "Could not open a temporary file for the recording: \(reason)"
            case .writeFailed(let reason):
                return "Writing the recording to disk failed: \(reason)"
            case .notSpooling:
                return "No recording is being spooled."
            }
        }
    }

    /// Why a buffer was refused. A plain value so the tap callback never boxes an error.
    enum Acceptance {
        case accepted
        /// Every preallocated slab is still waiting to be written.
        case spoolFull
        /// The buffer is larger than one slab, so it cannot be copied without allocating.
        case bufferTooLarge
        /// Not 16 kHz-shaped mono Float32; the converter should have produced that.
        case unsupportedFormat
    }

    struct Completed {
        let fileURL: URL
        let byteCount: Int
    }

    /// One preallocated destination for a single converted buffer.
    private final class Slab: @unchecked Sendable {
        let capacity: Int
        let storage: UnsafeMutableRawPointer
        /// The tap thread only ever takes this with a zero timeout, so the writer can never
        /// make the audio thread wait.
        let availability = DispatchSemaphore(value: 1)
        var byteCount = 0

        init(capacity: Int) {
            self.capacity = capacity
            self.storage = UnsafeMutableRawPointer.allocate(
                byteCount: capacity,
                alignment: MemoryLayout<Float>.alignment
            )
        }

        deinit {
            storage.deallocate()
        }

        func copy(from buffer: AVAudioPCMBuffer) -> Acceptance {
            guard buffer.format.commonFormat == .pcmFormatFloat32,
                  buffer.format.channelCount == 1,
                  let channelData = buffer.floatChannelData else {
                return .unsupportedFormat
            }

            let bytes: Int = Int(buffer.frameLength) * MemoryLayout<Float>.size
            guard bytes <= capacity else {
                return .bufferTooLarge
            }

            storage.copyMemory(from: channelData[0], byteCount: bytes)
            byteCount = bytes
            return .accepted
        }
    }

    private let slabs: [Slab]
    /// Preallocated single-producer single-consumer FIFO of slab indices. Slab permits cap
    /// occupancy, so it can never be overrun.
    private let readySlabIndices: UnsafeMutablePointer<Int>
    private var producedSequence: UInt64 = 0
    private var consumedSequence: UInt64 = 0
    private let readySource: DispatchSourceUserDataAdd
    private let writerQueue = DispatchQueue(label: "com.anilcan.mydikte.audio-spool-writer")

    // Touched only on `writerQueue`.
    private var fileURL: URL?
    private var fileHandle: FileHandle?
    private var byteCount = 0
    private var writeFailure: Failure?

    /// 32 slabs of 32 KB hold about 2.7 s of 16 kHz mono backlog, and one slab holds a whole
    /// converted buffer with room to spare (4096 input frames at 48 kHz convert to roughly
    /// 1360 output frames, 5.4 KB).
    init(slabCount: Int = 32, slabByteCapacity: Int = 32 * 1024) {
        let slabs: [Slab] = (0..<max(1, slabCount)).map { _ in
            Slab(capacity: max(MemoryLayout<Float>.size, slabByteCapacity))
        }
        self.slabs = slabs
        self.readySlabIndices = UnsafeMutablePointer<Int>.allocate(capacity: slabs.count)
        self.readySource = DispatchSource.makeUserDataAddSource(queue: writerQueue)
        readySource.setEventHandler { [weak self] in
            self?.drainReadySlabs()
        }
        readySource.resume()
    }

    deinit {
        readySource.cancel()
        // Every permit has to be back before the semaphores are freed: libdispatch traps when a
        // DispatchSemaphore is deallocated with a permit outstanding.
        for slab in slabs {
            slab.availability.wait()
        }
        for slab in slabs {
            slab.availability.signal()
        }
        closeAndRemoveFile()
        readySlabIndices.deallocate()
    }

    /// Opens a fresh temp file. Any previous spool is closed and removed first.
    func start() throws {
        try writerQueue.sync {
            closeAndRemoveFile()

            let url: URL = FileManager.default.temporaryDirectory
                .appendingPathComponent("mydikte-capture-\(UUID().uuidString).pcm")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw Failure.temporaryFileUnavailable(url.path)
            }
            do {
                fileHandle = try FileHandle(forWritingTo: url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw Failure.temporaryFileUnavailable(error.localizedDescription)
            }

            fileURL = url
            byteCount = 0
            writeFailure = nil
        }
    }

    /// Called from the tap callback: no allocation, no blocking wait, no filesystem access.
    func enqueue(_ buffer: AVAudioPCMBuffer) -> Acceptance {
        var acquiredIndex: Int?
        for index in slabs.indices where slabs[index].availability.wait(timeout: .now()) == .success {
            acquiredIndex = index
            break
        }
        guard let index = acquiredIndex else {
            return .spoolFull
        }

        let slab: Slab = slabs[index]
        let acceptance: Acceptance = slab.copy(from: buffer)
        guard acceptance == .accepted else {
            slab.availability.signal()
            return acceptance
        }

        readySlabIndices[Int(producedSequence % UInt64(slabs.count))] = index
        producedSequence &+= 1
        // Publishing through the source keeps the producer and consumer counters
        // single-threaded: the tap only writes `producedSequence`, the writer only reads
        // `consumedSequence`.
        readySource.add(data: 1)
        return .accepted
    }

    /// Waits for the writer to drain, then hands the finished file to the caller.
    /// Call only once the tap has stopped enqueuing, or an in-flight buffer will be refused.
    func finish() throws -> Completed {
        try withDrainedSlabs {
            try writerQueue.sync {
                if let writeFailure {
                    closeAndRemoveFile()
                    throw writeFailure
                }
                guard let fileURL, let fileHandle else {
                    closeAndRemoveFile()
                    throw Failure.notSpooling
                }
                do {
                    try fileHandle.close()
                } catch {
                    closeAndRemoveFile()
                    throw Failure.writeFailed(error.localizedDescription)
                }

                let completed = Completed(fileURL: fileURL, byteCount: byteCount)
                self.fileHandle = nil
                self.fileURL = nil
                byteCount = 0
                return completed
            }
        }
    }

    /// Closes and deletes the spool file, keeping nothing.
    func discard() {
        withDrainedSlabs {
            writerQueue.sync {
                closeAndRemoveFile()
                byteCount = 0
                writeFailure = nil
            }
        }
    }

    /// Runs only on `writerQueue`, one token at a time, in capture order.
    private func drainReadySlabs() {
        let readyCount = Int(readySource.data)
        for _ in 0..<readyCount {
            let slabIndex: Int = readySlabIndices[Int(consumedSequence % UInt64(slabs.count))]
            consumedSequence &+= 1
            write(slabs[slabIndex])
        }
    }

    private func write(_ slab: Slab) {
        defer { slab.availability.signal() }
        // After a write failure the rest of the recording is skipped rather than partially
        // written; `finish()` throws the recorded failure, so nothing is swallowed.
        guard writeFailure == nil, let fileHandle, slab.byteCount > 0 else {
            return
        }
        do {
            let data = Data(bytesNoCopy: slab.storage, count: slab.byteCount, deallocator: .none)
            try fileHandle.write(contentsOf: data)
            byteCount += slab.byteCount
        } catch {
            writeFailure = Failure.writeFailed(error.localizedDescription)
        }
    }

    /// Holds every slab permit for the duration of `operation`, which is only true once the
    /// writer has finished every token the tap produced.
    private func withDrainedSlabs<T>(_ operation: () throws -> T) rethrows -> T {
        for slab in slabs {
            slab.availability.wait()
        }
        defer {
            for slab in slabs {
                slab.availability.signal()
            }
        }
        return try operation()
    }

    private func closeAndRemoveFile() {
        try? fileHandle?.close()
        fileHandle = nil
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
    }
}
