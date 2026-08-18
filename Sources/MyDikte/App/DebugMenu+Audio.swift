import AVFoundation
import AppKit
import Synchronization
import os

/// The Audio area's own debug entry, added through Step 1's hook (`DebugMenu.register`) without
/// touching the shared menu file.
///
/// Capture is verified by ear on the real machine rather than by test, so this entry is how the
/// surface is exercised inside the signed bundle: it records for five seconds, encodes the
/// result, and prints the file paths, the duration and the measured cold start.
///
/// The live preview is here for the same reason and one more: it cannot be unit tested at all
/// (mocking a real-time recogniser produces confidence without coverage), and the two entries below
/// separate the two questions it raises. The microphone entry proves the plumbing, that a recogniser
/// was created, authorised, fed the tap's buffers and torn down, and it proves it with nobody
/// speaking. The clip entry feeds the Turkish test clip at its real rate and proves the thing the
/// plumbing cannot: that on-device `tr-TR` recognition actually returns Turkish words on this
/// machine.
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
        DebugMenu.register(title: "Audio: live preview only, 5 s from the microphone") {
            AudioDebugSession.shared.runLivePreviewFromMicrophone()
        }
        DebugMenu.register(title: "Audio: live preview from the Turkish test clip") {
            AudioDebugSession.shared.runLivePreviewFromClip()
        }
    }
}

/// Runs one hand-triggered recording and reports what it measured to stdout, which is why the
/// bundle is worth launching from a shell when using this entry.
@MainActor
private final class AudioDebugSession {
    static let shared = AudioDebugSession()

    /// The clip the plan's evidence was measured against: 16 kHz mono, Turkish, about 10 s.
    /// Regenerate with
    /// `say -v Yelda -o /tmp/tr_test.wav --data-format=LEI16@16000 "<sentence>"`.
    private static let clipPath = "/tmp/tr_test.wav"

    /// What the converter emits per tap callback at 48 kHz in, 16 kHz out, measured in
    /// `evidence/step-08-format-probe.txt`, and therefore the granularity and the pacing the clip is
    /// fed at so the preview sees what a real dictation gives it.
    private static let clipChunkFrames: AVAudioFrameCount = 1_360

    private let capture = AudioCapture()
    private let livePreview = LivePreview()
    private let levels = LevelTally()
    /// `print` goes nowhere in a bundle launched with `open`, so everything the preview entries
    /// report goes to the unified log instead.
    private let logger = Logger(subsystem: BundleInfo.bundleIdentifier, category: "AudioDebug")
    private var isRecording = false
    private var partials: [String] = []

    private init() {
        // Registered before the first start, because the tap captures the handler when it is
        // installed.
        capture.setLevelHandler { [levels] level in
            levels.record(level)
        }
        capture.setBufferSink { [livePreview] buffer in
            livePreview.accept(buffer)
        }
        livePreview.onPreviewText = { [weak self] text in
            self?.partials.append(text)
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

    /// The preview alone: the real microphone, the real recogniser, no transcription, no cleanup and
    /// nothing inserted anywhere.
    func runLivePreviewFromMicrophone() {
        guard !isRecording else {
            logger.notice("a debug recording is already running")
            return
        }
        isRecording = true
        Task {
            await runPreviewFromMicrophone()
            isRecording = false
        }
    }

    func runLivePreviewFromClip() {
        guard !isRecording else {
            logger.notice("a debug recording is already running")
            return
        }
        isRecording = true
        Task {
            await runPreviewFromClip()
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

    private func runPreviewFromMicrophone() async {
        partials = []
        guard startPreview() else {
            return
        }

        do {
            try capture.beginKeeping()
            logger.notice("live preview probe: listening to the microphone for 5 s")
            try await Task.sleep(for: .seconds(5))
            livePreview.stop()
            let recording: AudioCapture.Recording = try capture.stop()
            remove(recording.fileURL)
            await settle()
            report(audioSeconds: recording.duration, source: "microphone")
        } catch {
            livePreview.stop()
            capture.cancelWarmUp()
            logger.error("live preview probe failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func runPreviewFromClip() async {
        partials = []
        guard startPreview() else {
            return
        }

        do {
            let chunks: [AVAudioPCMBuffer] = try Self.clipChunks()
            logger.notice(
                """
                live preview probe: feeding \(chunks.count, privacy: .public) chunk(s) of \
                \(Self.clipChunkFrames, privacy: .public) frames from \(Self.clipPath, privacy: .public)
                """
            )
            for chunk in chunks {
                livePreview.accept(chunk)
                // Fed at the rate the microphone would, 85 ms of audio per chunk, so the recogniser
                // sees the same arrival pattern a real dictation gives it and the ring is exercised
                // at its real depth rather than flooded.
                try await Task.sleep(for: .milliseconds(85))
            }
            livePreview.stop()
            await settle()
            report(audioSeconds: Double(chunks.count) * Double(Self.clipChunkFrames) / AudioCapture.sampleRate,
                   source: "clip")
        } catch {
            livePreview.stop()
            logger.error("live preview probe failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Starts the preview and says why there is none when there is none, which is the whole point of
    /// these entries: the failure has to be readable without a voice and without a screen.
    private func startPreview() -> Bool {
        let readiness: LivePreview.Readiness = livePreview.start(
            isEnabledInSettings: Settings.load().livePreviewEnabled
        )
        guard readiness.isReady else {
            logger.error("live preview probe: no preview, because \(readiness.logMessage, privacy: .public)")
            return false
        }
        return true
    }

    /// The final result arrives after the last buffer, so the probe waits for it rather than
    /// reporting a partial list and calling it the answer.
    private func settle() async {
        do {
            try await Task.sleep(for: .seconds(2))
        } catch {
            logger.notice("live preview probe: cancelled while waiting for the final result")
        }
    }

    /// Every partial string, verbatim. This is a debug entry the user triggers by hand, and the
    /// strings are the evidence it exists to produce; the app's own path never logs them.
    private func report(audioSeconds: Double, source: String) {
        logger.notice(
            """
            live preview probe (\(source, privacy: .public)): \
            \(audioSeconds, format: .fixed(precision: 2), privacy: .public) s of audio, \
            \(self.partials.count, privacy: .public) partial(s)
            """
        )
        for (index, partial) in partials.enumerated() {
            logger.notice("live preview partial \(index + 1, privacy: .public): \(partial, privacy: .public)")
        }
        if partials.isEmpty {
            logger.notice("live preview probe: no partial results at all, which is what silence looks like")
        }
    }

    /// The clip as the tap would have delivered it: 16 kHz mono Float32, in converter-sized chunks.
    private static func clipChunks() throws -> [AVAudioPCMBuffer] {
        let file = try AVAudioFile(
            forReading: URL(filePath: clipPath),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format: AVAudioFormat = file.processingFormat
        guard format.sampleRate == AudioCapture.sampleRate, format.channelCount == 1 else {
            throw AudioCapture.Failure.unsupportedInputFormat(
                channelCount: format.channelCount,
                sampleRate: format.sampleRate
            )
        }
        guard let whole = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AudioCapture.Failure.converterUnavailable
        }
        try file.read(into: whole)
        guard let samples = whole.floatChannelData?[0], whole.frameLength > 0 else {
            throw AudioCapture.Failure.conversionFailed
        }

        var chunks: [AVAudioPCMBuffer] = []
        var offset: AVAudioFrameCount = 0
        while offset < whole.frameLength {
            let frames: AVAudioFrameCount = min(clipChunkFrames, whole.frameLength - offset)
            guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let destination = chunk.floatChannelData else {
                throw AudioCapture.Failure.converterUnavailable
            }
            destination[0].update(from: samples + Int(offset), count: Int(frames))
            chunk.frameLength = frames
            chunks.append(chunk)
            offset += frames
        }
        return chunks
    }

    private func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logger.warning(
                """
                could not remove \(url.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
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
