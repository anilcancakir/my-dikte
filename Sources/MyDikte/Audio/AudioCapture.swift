import AVFoundation
import Foundation
import Synchronization

/// Owns the microphone: an `AVAudioEngine` input tap, converted to 16 kHz mono Float32 and
/// spooled to a temp file, plus a per-buffer level for the recording indicator.
///
/// **Deliberately not `@MainActor`, and it must stay that way.** `AVAudioEngine.installTap`
/// delivers its callbacks on an audio worker thread, and under Swift 6 strict concurrency a
/// `@MainActor` call from that thread traps in `dispatch_assert_queue_fail` (SIGTRAP) and kills
/// the process. The compiler does not warn about it, so the annotation staying off is the only
/// guard there is; `references/parakey/swift/Sources/Presspeech/main.swift:2965-2986` records the
/// same crash. Mutable control-plane state (the engine, the level handler, the buffer sink, the
/// configuration observer) is guarded by `lock`. Everything the tap touches is either captured
/// immutably when the tap is installed or an atomic, so the callback never waits on that lock,
/// never allocates and never logs.
///
/// Warm-up exists because the cold start was measured, not assumed: median 156.4 ms from
/// `engine.start()` to the first tap buffer, with no warm path and nothing recoverable in
/// `prepare()` (`.ac/plans/my-dikte-swift-macos/evidence/step-08-cold-start.txt`). So the first
/// modifier of a two-modifier chord calls `warmUp()`, the second calls `beginKeeping()`, and the
/// 150 to 300 ms human gap between them covers the start cost. Nothing here knows about the
/// shortcut layer; Step 17 connects the two.
final class AudioCapture: @unchecked Sendable {
    /// What a finished recording hands to the pipeline.
    struct Recording: Sendable {
        /// Raw 16 kHz mono Float32 PCM, in the temp directory. The caller owns the file.
        let fileURL: URL
        /// Audio actually captured, derived from the spooled byte count.
        let duration: TimeInterval
        /// One raw RMS value per converted buffer, in capture order: Step 3's VAD input.
        /// Raw, not the gain-scaled indicator level, because the VAD's thresholds are in dBFS.
        let chunkRMS: [Double]
        /// Mean seconds per `chunkRMS` entry. It is a mean rather than a constant because
        /// `AVAudioConverter` returns a variable frame count per call: 4096 frames in gave 1360
        /// out where the ratio predicts 1365
        /// (`.ac/plans/my-dikte-swift-macos/evidence/step-08-format-probe.txt`).
        let chunkSeconds: Double
        /// `engine.start()` to the first tap buffer, the cold start this step measured.
        let coldStart: TimeInterval
        /// First retained buffer to `stop()`, for comparison against `duration`.
        let wallClock: TimeInterval
    }

    enum Failure: Error, LocalizedError {
        case microphoneAccessDenied
        case unsupportedInputFormat(channelCount: AVAudioChannelCount, sampleRate: Double)
        case converterUnavailable
        case engineStartFailed(String)
        case notRecording
        case spoolOverflow
        case bufferRejected
        case conversionFailed
        case recordingTooLong(seconds: Double)
        case inputConfigurationChanged

        var errorDescription: String? {
            switch self {
            case .microphoneAccessDenied:
                return "MyDikte has no microphone access. Grant it in System Settings, "
                    + "Privacy & Security, Microphone."
            case .unsupportedInputFormat(let channelCount, let sampleRate):
                return "The input device reports \(channelCount) channels at \(Int(sampleRate)) Hz; "
                    + "MyDikte records from a mono input."
            case .converterUnavailable:
                return "Could not build the 16 kHz mono conversion path for this input device."
            case .engineStartFailed(let reason):
                return "The audio engine did not start: \(reason)"
            case .notRecording:
                return "No recording is in progress."
            case .spoolOverflow:
                return "The disk writer fell behind the microphone, so the recording lost audio."
            case .bufferRejected:
                return "The input device delivered a buffer this recording cannot hold."
            case .conversionFailed:
                return "Converting the microphone input to 16 kHz mono failed."
            case .recordingTooLong(let seconds):
                return "The recording passed \(Int(seconds / 60)) minutes, which is longer than "
                    + "MyDikte keeps level data for."
            case .inputConfigurationChanged:
                return "The input device changed while recording, so the recording is incomplete."
            }
        }
    }

    /// The format everything downstream expects: Groq is fed 16 kHz mono, and the VAD's
    /// chunk arithmetic is in this rate.
    static let sampleRate: Double = 16_000

    /// Frames per tap callback. 4096 at 48 kHz is about 85 ms, which is also the indicator's
    /// update rate.
    private static let tapBufferSize: AVAudioFrameCount = 4096

    /// Per-buffer RMS slots, preallocated because the tap cannot grow an array. 32768 slots at
    /// roughly 85 ms each is about 46 minutes; running out is a thrown error, never a truncated
    /// VAD input.
    private static let rmsCapacity: Int = 32_768

    /// Nominal seconds of audio per converted buffer, used only to report how long a recording
    /// had grown when the preallocated level storage ran out.
    fileprivate static var tapChunkSeconds: Double {
        Double(tapBufferSize) / 48_000
    }

    private let lock = NSLock()
    private let spool = AudioSpool()
    private let tapState = TapState(rmsCapacity: AudioCapture.rmsCapacity)
    private var engine: AVAudioEngine?
    private var levelHandler: (@Sendable (Float) -> Void)?
    private var bufferSink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var configurationObserver: NSObjectProtocol?

    /// Set this before starting; the tap captures the handler when it is installed, so a handler
    /// registered mid-recording would not be seen. It is called on the audio thread once per
    /// converted buffer with a value between 0 and 1, so hop to the main actor at the call site.
    func setLevelHandler(_ handler: @escaping @Sendable (Float) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        levelHandler = handler
    }

    /// Registers a second consumer of the converted 16 kHz mono buffers, for the live preview.
    ///
    /// Same contract as `setLevelHandler`, and two hard rules on top of it, because this one is
    /// handed the audio itself. The buffer is the converter's reused output, so the sink must copy
    /// what it wants synchronously and must never retain it: the next callback overwrites it. And the
    /// sink runs on the audio thread, so it may not allocate, may not block on a lock and may not
    /// touch the main actor; `LivePreview.accept(_:)` is written to that contract.
    ///
    /// Set this before starting, like the level handler: the tap captures it when it is installed.
    func setBufferSink(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        bufferSink = sink
    }

    /// Starts the engine with the tap installed and every buffer discarded, so that
    /// `beginKeeping()` costs nothing. Idempotent while the engine is up.
    func warmUp() throws {
        lock.lock()
        defer { lock.unlock() }
        guard engine == nil else {
            return
        }
        try startEngine(keeping: false)
    }

    /// Starts retaining buffers. Starts the engine first if nothing warmed it, which is the
    /// path that pays the measured 156 ms.
    func beginKeeping() throws {
        lock.lock()
        defer { lock.unlock() }
        guard engine != nil else {
            try startEngine(keeping: true)
            return
        }
        // A repeated call must not move the mark the recorded duration is compared against.
        guard !tapState.isKeeping.load(ordering: .acquiring) else {
            return
        }
        tapState.firstKeptBufferUptime.store(0, ordering: .relaxed)
        tapState.isKeeping.store(true, ordering: .releasing)
    }

    /// Stops the engine and throws away whatever was spooled. Also the cancel path for a
    /// recording in progress: it is the same engine and the same spool.
    func cancelWarmUp() {
        lock.lock()
        defer { lock.unlock() }
        guard let engine else {
            return
        }
        tapState.isKeeping.store(false, ordering: .releasing)
        tearDown(engine)
        self.engine = nil
        spool.discard()
    }

    /// Stops the engine and hands over the spooled file, its duration and the per-chunk RMS
    /// series the VAD needs.
    func stop() throws -> Recording {
        lock.lock()
        defer { lock.unlock() }

        guard let engine else {
            throw Failure.notRecording
        }

        // Stop retaining before tearing the engine down: `removeTap(onBus:)` does not wait for
        // in-flight tap callbacks, so a straggler has to find this flag already false rather
        // than enqueue into a spool that is being finished.
        let wasKeeping: Bool = tapState.isKeeping.exchange(false, ordering: .acquiringAndReleasing)
        let stopUptime: UInt64 = DispatchTime.now().uptimeNanoseconds
        tearDown(engine)
        self.engine = nil

        guard wasKeeping else {
            spool.discard()
            throw Failure.notRecording
        }

        if let failure = tapState.recordedFailure() {
            spool.discard()
            throw failure
        }

        let completed: AudioSpool.Completed = try spool.finish()
        let frameCount: Int = completed.byteCount / MemoryLayout<Float>.size
        let duration: TimeInterval = Double(frameCount) / Self.sampleRate
        let chunkRMS: [Double] = tapState.copyRMSValues()

        return Recording(
            fileURL: completed.fileURL,
            duration: duration,
            chunkRMS: chunkRMS,
            chunkSeconds: chunkRMS.isEmpty ? 0 : duration / Double(chunkRMS.count),
            coldStart: tapState.coldStart(),
            wallClock: tapState.wallClock(until: stopUptime)
        )
    }

    // MARK: - Engine lifecycle, all of it under `lock`

    private func startEngine(keeping: Bool) throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            throw Failure.microphoneAccessDenied
        default:
            // `.notDetermined` is deliberately allowed through: starting the engine is what
            // raises the system prompt, and asking twice would show it twice.
            break
        }

        let engine = AVAudioEngine()
        let inputFormat: AVAudioFormat = engine.inputNode.inputFormat(forBus: 0)
        // The measured default input here is 48 kHz mono, so the graph resamples and never
        // downmixes. A multi-channel device fails loudly rather than being mixed by untested
        // code (`evidence/step-08-format-probe.txt`).
        guard inputFormat.channelCount == 1, inputFormat.sampleRate > 0 else {
            throw Failure.unsupportedInputFormat(
                channelCount: inputFormat.channelCount,
                sampleRate: inputFormat.sampleRate
            )
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = TapConverter(
            inputFormat: inputFormat,
            outputFormat: targetFormat,
            maximumInputFrames: Self.tapBufferSize * 4
        ) else {
            throw Failure.converterUnavailable
        }

        try spool.start()
        tapState.reset(keeping: keeping)

        let state: TapState = tapState
        let spool: AudioSpool = self.spool
        let handler: (@Sendable (Float) -> Void)? = levelHandler
        let sink: (@Sendable (AVAudioPCMBuffer) -> Void)? = bufferSink

        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: Self.tapBufferSize,
            format: inputFormat
        ) { buffer, _ in
            let arrivalUptime: UInt64 = DispatchTime.now().uptimeNanoseconds
            if state.firstBufferUptime.load(ordering: .relaxed) == 0 {
                state.firstBufferUptime.store(arrivalUptime, ordering: .relaxed)
            }
            guard state.isKeeping.load(ordering: .acquiring) else {
                return
            }
            if state.firstKeptBufferUptime.load(ordering: .relaxed) == 0 {
                state.firstKeptBufferUptime.store(arrivalUptime, ordering: .relaxed)
            }

            guard let converted = converter.convert(buffer) else {
                state.conversionFailed.store(true, ordering: .relaxed)
                return
            }
            // A short or empty output is normal: the resampler holds a remainder between calls.
            guard converted.frameLength > 0, let samples = converted.floatChannelData else {
                return
            }

            switch spool.enqueue(converted) {
            case .accepted:
                break
            case .spoolFull:
                state.spoolFull.store(true, ordering: .relaxed)
                return
            case .bufferTooLarge, .unsupportedFormat:
                state.bufferRejected.store(true, ordering: .relaxed)
                return
            }

            let rms: Float = TapState.rootMeanSquare(samples[0], frameCount: Int(converted.frameLength))
            state.appendRMS(Double(rms))
            // Gain of 15 matches `references/pindrop/.../AudioRecorder.swift:326-372`: speech at
            // a normal distance reads around 0.02 RMS, which without gain is an invisible bar.
            handler?(min(1.0, rms * 15))
            // Last, and only while keeping, so a warm-up is never fed to the preview recogniser and
            // nothing here can delay the spool that holds the actual dictation.
            sink?(converted)
        }

        registerConfigurationObserver(for: engine)
        engine.prepare()
        // The clock starts here, after `prepare()` and immediately before `start()`, to match
        // the method behind the 156 ms median in evidence/step-08-cold-start.txt.
        tapState.engineStartUptime.store(DispatchTime.now().uptimeNanoseconds, ordering: .releasing)
        do {
            try engine.start()
        } catch {
            tearDown(engine)
            spool.discard()
            throw Failure.engineStartFailed(error.localizedDescription)
        }

        self.engine = engine
    }

    private func tearDown(_ engine: AVAudioEngine) {
        removeConfigurationObserver()
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        // AVAudioIOUnit can still be processing a device change after `stop()`; releasing the
        // engine's last reference right here crashed inside AVFAudio on macOS 26.4, so the
        // reference is held for two seconds (references/pindrop/.../AudioRecorder.swift:923-928).
        let hold = EngineHold(engine)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            _ = hold
        }
    }

    private func registerConfigurationObserver(for engine: AVAudioEngine) {
        // Plugging AirPods in mid-recording stops the engine and posts this. Without the flag
        // the recording would simply end early and be transcribed as if complete, which is the
        // silent-truncation failure; with it, `stop()` says what happened.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [tapState] _ in
            tapState.configurationChanged.store(true, ordering: .relaxed)
        }
    }

    private func removeConfigurationObserver() {
        guard let configurationObserver else {
            return
        }
        NotificationCenter.default.removeObserver(configurationObserver)
        self.configurationObserver = nil
    }
}

/// Everything the tap callback touches. Held by the callback as an immutable capture, so the
/// callback never reads a mutable property of `AudioCapture` and never takes its lock.
private final class TapState: @unchecked Sendable {
    let isKeeping = Atomic<Bool>(false)
    let engineStartUptime = Atomic<UInt64>(0)
    let firstBufferUptime = Atomic<UInt64>(0)
    let firstKeptBufferUptime = Atomic<UInt64>(0)
    let spoolFull = Atomic<Bool>(false)
    let bufferRejected = Atomic<Bool>(false)
    let conversionFailed = Atomic<Bool>(false)
    let rmsOverflowed = Atomic<Bool>(false)
    let configurationChanged = Atomic<Bool>(false)

    /// Preallocated: the tap writes one value per converted buffer, and only the tap writes.
    private let rmsValues: UnsafeMutablePointer<Double>
    private let rmsCapacity: Int
    private let rmsCount = Atomic<Int>(0)

    init(rmsCapacity: Int) {
        self.rmsCapacity = max(1, rmsCapacity)
        self.rmsValues = UnsafeMutablePointer<Double>.allocate(capacity: self.rmsCapacity)
    }

    deinit {
        rmsValues.deallocate()
    }

    /// Called from the tap callback. Single producer, so the count can be read and stored
    /// without a compare-exchange.
    func appendRMS(_ value: Double) {
        let index: Int = rmsCount.load(ordering: .relaxed)
        guard index < rmsCapacity else {
            rmsOverflowed.store(true, ordering: .relaxed)
            return
        }
        rmsValues[index] = value
        rmsCount.store(index + 1, ordering: .releasing)
    }

    /// Control plane only, after the engine has stopped.
    func copyRMSValues() -> [Double] {
        let count: Int = rmsCount.load(ordering: .acquiring)
        return Array(UnsafeBufferPointer(start: rmsValues, count: count))
    }

    func reset(keeping: Bool) {
        engineStartUptime.store(0, ordering: .relaxed)
        firstBufferUptime.store(0, ordering: .relaxed)
        firstKeptBufferUptime.store(0, ordering: .relaxed)
        spoolFull.store(false, ordering: .relaxed)
        bufferRejected.store(false, ordering: .relaxed)
        conversionFailed.store(false, ordering: .relaxed)
        rmsOverflowed.store(false, ordering: .relaxed)
        configurationChanged.store(false, ordering: .relaxed)
        rmsCount.store(0, ordering: .relaxed)
        isKeeping.store(keeping, ordering: .releasing)
    }

    /// The one hard failure the recording collected, if any. Every one of these means the file
    /// is missing audio or is not what the caller asked for, so none of them may pass silently.
    func recordedFailure() -> AudioCapture.Failure? {
        if spoolFull.load(ordering: .acquiring) {
            return .spoolOverflow
        }
        if bufferRejected.load(ordering: .acquiring) {
            return .bufferRejected
        }
        if conversionFailed.load(ordering: .acquiring) {
            return .conversionFailed
        }
        if rmsOverflowed.load(ordering: .acquiring) {
            return .recordingTooLong(
                seconds: Double(rmsCapacity) * Double(AudioCapture.tapChunkSeconds)
            )
        }
        if configurationChanged.load(ordering: .acquiring) {
            return .inputConfigurationChanged
        }
        return nil
    }

    func coldStart() -> TimeInterval {
        let started: UInt64 = engineStartUptime.load(ordering: .acquiring)
        let first: UInt64 = firstBufferUptime.load(ordering: .acquiring)
        guard started > 0, first > started else {
            return 0
        }
        return Double(first - started) / 1_000_000_000
    }

    func wallClock(until stopUptime: UInt64) -> TimeInterval {
        let first: UInt64 = firstKeptBufferUptime.load(ordering: .acquiring)
        guard first > 0, stopUptime > first else {
            return 0
        }
        return Double(stopUptime - first) / 1_000_000_000
    }

    static func rootMeanSquare(_ samples: UnsafePointer<Float>, frameCount: Int) -> Float {
        guard frameCount > 0 else {
            return 0
        }
        var sum: Float = 0
        for index in 0..<frameCount {
            let sample: Float = samples[index]
            sum += sample * sample
        }
        return (sum / Float(frameCount)).squareRoot()
    }
}

/// Reused across tap callbacks so the callback allocates nothing: the converter and its output
/// buffer both exist before the engine starts.
private final class TapConverter: @unchecked Sendable {
    /// Handed to the converter's input block. A class so the block can mutate it without the
    /// block itself being mutable state. `@unchecked Sendable` because
    /// `AVAudioConverterInputBlock` is typed `@Sendable` while the converter only ever calls it
    /// synchronously, on the thread already inside `convert(_:)`.
    private final class InputState: @unchecked Sendable {
        var buffer: AVAudioPCMBuffer?
        var consumed = false
    }

    private let converter: AVAudioConverter
    /// One buffer is the whole free list. The converted buffer never escapes the callback: the
    /// spool copies it synchronously and the level handler only ever sees a `Float`, so a second
    /// buffer could never be in use while this one is being filled.
    private let outputBuffer: AVAudioPCMBuffer
    private let inputState = InputState()

    init?(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat, maximumInputFrames: AVAudioFrameCount) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        // `frames * ratio + 1`, sized for four times the requested tap buffer, because the
        // converter's output frame count per call is not a fixed function of its input
        // (4096 in gave 1360 out where the ratio predicts 1365) and a device may hand over a
        // larger buffer than the one asked for.
        let ratio: Double = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(maximumInputFrames) * ratio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }
        self.converter = converter
        self.outputBuffer = outputBuffer
    }

    /// Returns the reused output buffer, whose `frameLength` is the only valid length to read.
    /// Appending a computed stride instead is what makes spooled audio play at the wrong speed.
    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        inputState.buffer = input
        inputState.consumed = false
        defer {
            inputState.buffer = nil
            inputState.consumed = false
        }

        outputBuffer.frameLength = 0
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { [inputState] _, outStatus in
            if inputState.consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputState.consumed = true
            outStatus.pointee = .haveData
            return inputState.buffer
        }

        let status: AVAudioConverterOutputStatus = converter.convert(
            to: outputBuffer,
            error: &error,
            withInputFrom: inputBlock
        )
        guard error == nil, status != .error else {
            return nil
        }
        return outputBuffer
    }
}

/// Carries the engine into the delayed release in `tearDown`. `AVAudioEngine` is not `Sendable`
/// and this box never touches it; it only keeps it alive.
private final class EngineHold: @unchecked Sendable {
    let engine: AVAudioEngine

    init(_ engine: AVAudioEngine) {
        self.engine = engine
    }
}
