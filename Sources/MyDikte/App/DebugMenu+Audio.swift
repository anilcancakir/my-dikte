import AVFoundation
import AppKit
import Synchronization

/// The Audio area's own debug entry, added through Step 1's hook (`DebugMenu.register`) without
/// touching the shared menu file.
///
/// Capture is verified by ear on the real machine rather than by test, so this entry is how the
/// surface is exercised inside the signed bundle: it records for five seconds, encodes the
/// result, and prints the file paths, the duration and the measured cold start.
///
/// Swift runs no code automatically for a file that is not `main.swift`, so `register()` has to
/// be called. `App/AppDelegate.swift` belongs to Step 17 and this step must not edit it, so that
/// one call lands with that step; until it does, the entry is in the binary but not in the
/// running app's menu.
@MainActor
enum DebugMenuAudio {
    static func register() {
        DebugMenu.register(title: "Audio: record 5 seconds") {
            AudioDebugSession.shared.recordFiveSeconds()
        }
    }
}

/// Runs one hand-triggered recording and reports what it measured to stdout, which is why the
/// bundle is worth launching from a shell when using this entry.
@MainActor
private final class AudioDebugSession {
    static let shared = AudioDebugSession()

    private let capture = AudioCapture()
    private let levels = LevelTally()
    private var isRecording = false

    private init() {
        // Registered before the first start, because the tap captures the handler when it is
        // installed.
        capture.setLevelHandler { [levels] level in
            levels.record(level)
        }
    }

    func recordFiveSeconds() {
        guard !isRecording else {
            print("[audio] a debug recording is already running")
            return
        }
        isRecording = true
        Task {
            await runFiveSecondRecording()
            isRecording = false
        }
    }

    private func runFiveSecondRecording() async {
        levels.reset()
        do {
            // No `warmUp()` first, deliberately: this is the path that pays the cold start, and
            // printing that number is half of what this entry exists for.
            try capture.beginKeeping()
            print("[audio] recording for 5 seconds, speak now")
            try await Task.sleep(for: .seconds(5))
            let recording: AudioCapture.Recording = try capture.stop()

            let m4aURL: URL = recording.fileURL.deletingPathExtension().appendingPathExtension("m4a")
            let pcmURL: URL = recording.fileURL
            try await Task.detached(priority: .userInitiated) {
                try AudioEncoder.encodeM4A(pcmFileURL: pcmURL, to: m4aURL)
            }.value

            print(String(
                format: "[audio] coldStart=%.1f ms duration=%.3f s wallClock=%.3f s chunks=%d "
                    + "chunkSeconds=%.4f level n=%d min=%.3f max=%.3f",
                recording.coldStart * 1000,
                recording.duration,
                recording.wallClock,
                recording.chunkRMS.count,
                recording.chunkSeconds,
                levels.count.load(ordering: .relaxed),
                levels.minimum,
                levels.maximum
            ))
            print("[audio] pcm: \(recording.fileURL.path)")
            print("[audio] m4a: \(m4aURL.path)")
        } catch {
            print("[audio] FAILED: \(error.localizedDescription)")
        }
    }
}

/// Counts what the level callback delivered. The callback runs on the audio thread, where
/// printing would allocate and take a lock, so it only touches atomics and the numbers are read
/// back afterwards.
private final class LevelTally: @unchecked Sendable {
    let count = Atomic<Int>(0)
    private let minimumMilli = Atomic<Int>(1_000)
    private let maximumMilli = Atomic<Int>(-1)

    func record(_ level: Float) {
        let milli = Int(level * 1000)
        count.wrappingAdd(1, ordering: .relaxed)
        // Single producer, so a plain compare and store is enough.
        if milli < minimumMilli.load(ordering: .relaxed) {
            minimumMilli.store(milli, ordering: .relaxed)
        }
        if milli > maximumMilli.load(ordering: .relaxed) {
            maximumMilli.store(milli, ordering: .relaxed)
        }
    }

    func reset() {
        count.store(0, ordering: .relaxed)
        minimumMilli.store(1_000, ordering: .relaxed)
        maximumMilli.store(-1, ordering: .relaxed)
    }

    var minimum: Double {
        Double(minimumMilli.load(ordering: .relaxed)) / 1000
    }

    var maximum: Double {
        Double(maximumMilli.load(ordering: .relaxed)) / 1000
    }
}
