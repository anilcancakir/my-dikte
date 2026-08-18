import AVFoundation
import AppKit
import os

/// Owns the status item and its menu. Every AppKit lifecycle callback lands here on the main
/// actor, per this project's concurrency convention for UI-owning types.
///
/// This is also where the app is actually assembled: the shortcut layer, the pipeline, the status
/// item and the settings window are all instantiated here and connected through the closures each
/// of them exposes. Nothing else in the app knows about more than one of them.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var pipeline: DictationPipeline?
    private var shortcuts: ShortcutCoordinator?
    private var permissionGate: PermissionGate?
    private let logger = Logger(subsystem: BundleInfo.bundleIdentifier, category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist's LSUIElement only governs the process LaunchServices started; setting the
        // policy here too makes accessory mode hold however the binary was actually launched
        // (for example, directly from the built .build/debug path during development).
        NSApplication.shared.setActivationPolicy(.accessory)
        // Built before the debug entries and the status item, because both wire onto it.
        pipeline = DictationPipeline()
        registerDebugEntries()
        setUpStatusItem()
        setUpShortcuts()
    }

    /// Swift runs nothing automatically outside `main.swift`, and the toolchain rejects an
    /// Objective-C `+load` class method, so a `DebugMenu+<Area>.swift` file cannot register
    /// itself. Every area's registrar therefore needs one call from here, and this is the only
    /// place in the app that may make it: four parallel workers each adding their own
    /// `applicationDidFinishLaunching` would be four duplicate declarations.
    ///
    /// Registration runs before the status item is built, but that is not load-bearing: the
    /// Debug submenu populates in `menuNeedsUpdate(_:)`, so an entry registered later would
    /// still appear.
    private func registerDebugEntries() {
        guard DebugMenu.isEnabled else {
            return
        }
        DebugMenuAudio.register()
        DebugMenuHotkeys.register()
        DebugMenuStore.register()
        DebugMenuOutput.register()
        registerPipelineDebugEntries()
    }

    /// Builds the real status item (Step 15) and its settings window, then connects the pipeline to
    /// both directions of it: the menu's actions drive the pipeline, and the pipeline's stage
    /// transitions drive the icon. `StatusItemController` is not edited to do this; it exposes a
    /// closure per seam and this is the one place that fills them in.
    private func setUpStatusItem() {
        let windowController = SettingsWindowController()
        settingsWindowController = windowController

        let controller = StatusItemController()
        controller.onOpenSettings = { [weak windowController] in
            windowController?.show()
        }
        controller.onStart = { [weak self] in
            self?.pipeline?.startRequested()
        }
        controller.onStop = { [weak self] in
            self?.pipeline?.stopRequested()
        }
        controller.onCancel = { [weak self] in
            self?.pipeline?.cancelRequested()
        }
        controller.installDebugMenuItem(DebugMenu.buildMenuItem())
        statusItemController = controller

        pipeline?.onStageChange = { [weak controller] stage in
            controller?.setState(Self.statusState(for: stage))
        }
        pipeline?.onFailure = { [weak controller] _ in
            // The message itself is carried by the indicator panel and the log; the status item
            // only has an icon, so it shows that something went wrong and nothing more. No alert:
            // a modal here would steal the focus the dictation just went to.
            controller?.setState(.error)
        }
    }

    private static func statusState(for stage: PipelineStage) -> StatusItemController.State {
        switch stage {
        case .idle:
            return .idle
        case .recording:
            return .recording
        case .working, .inserting:
            return .working
        }
    }

    /// Connects the two halves of Wave 2 that were deliberately left unconnected: the chord's four
    /// events map onto the audio engine's warm-up, keep, cancel and stop.
    private func setUpShortcuts() {
        let coordinator = ShortcutCoordinator { [weak self] event in
            self?.handle(event)
        }
        shortcuts = coordinator
        startShortcuts()
    }

    private func handle(_ event: ShortcutCoordinator.Event) {
        guard let pipeline else {
            return
        }
        switch event {
        case .firstModifierDown:
            pipeline.warmUpRequested()
        case .chordCompleted:
            pipeline.startRequested()
        case .chordReleased:
            pipeline.stopRequested()
        case .chordAbandoned:
            pipeline.warmUpAbandoned()
        case .toggleRequested:
            pipeline.toggleRequested()
        case .cancelRequested:
            pipeline.cancelRequested()
        case .promptToggleRequested:
            // Mode 2: the same dictation, rewritten into an English prompt for Opus 5 and inserted
            // without being submitted. The pipeline supported this from the start; until this
            // shortcut existed it was reachable only from the debug menu.
            pipeline.toggleRequested(mode: .prompt)
        }
    }

    /// Starts both shortcut mechanisms, and retries the event tap once the Accessibility grant
    /// arrives. Without the retry the app would need a relaunch to get its chord back, since macOS
    /// posts no notification when the grant is given and the user typically gives it minutes after
    /// launch. The keyed toggle and cancel go through Carbon and work without the grant either way.
    private func startShortcuts() {
        do {
            try shortcuts?.start()
            logger.notice("shortcuts started, tap enabled: \(self.shortcuts?.isTapEnabled == true, privacy: .public)")
        } catch {
            logger.error("the event tap did not start: \(error.localizedDescription, privacy: .public)")

            let gate = permissionGate ?? PermissionGate()
            permissionGate = gate
            gate.requestAccessibility()
            gate.startMonitoring { [weak self] state in
                guard state == .granted else {
                    return
                }
                self?.permissionGate?.stopMonitoring()
                self?.startShortcuts()
            }
        }
    }
}

// MARK: - The pipeline's hands-on QA surface

/// What can go wrong turning a test clip into a `Recording`. Debug-only, but a typed error all the
/// same: a harness that fails silently is worse than no harness.
private enum PipelineProbeError: Error, LocalizedError {
    case clipMissing(String)
    case unexpectedClipFormat(sampleRate: Double, channels: AVAudioChannelCount)
    case clipUnreadable

    var errorDescription: String? {
        switch self {
        case .clipMissing(let path):
            return "No clip at \(path). Generate one with "
                + "`say -v Yelda -o \(path) --data-format=LEI16@16000 \"<sentence>\"`."
        case .unexpectedClipFormat(let sampleRate, let channels):
            return "The clip is \(Int(sampleRate)) Hz, \(channels) channels; this probe needs 16 kHz mono."
        case .clipUnreadable:
            return "The clip decoded to no samples."
        }
    }
}

extension AppDelegate {
    /// The Turkish clip the plan's evidence was measured against.
    private static let probeClipPath = "/tmp/tr_test.wav"

    /// Time between clicking a menu item and the run starting. Clicking a status-item menu makes
    /// MyDikte frontmost, so the tester (or a script) needs a window in which to put the caret back
    /// where the dictation should land.
    private static let probeCountdown: Duration = .seconds(5)

    /// Registers the entries that drive the whole pipeline by hand inside the signed bundle.
    ///
    /// The keyboard half of this step cannot be automated at all: a held two-modifier chord, a real
    /// voice and a real caret need a human. Everything after the microphone can be, and these
    /// entries are how: two of them feed a real Turkish clip through the real clients into the real
    /// inserter, and one feeds near-silence to prove the VAD short circuit makes no API call.
    fileprivate func registerPipelineDebugEntries() {
        DebugMenu.register(title: "Pipeline: dictate from the test clip in 5 s") { [weak self] in
            self?.runClipProbe(mode: .dictate)
        }
        DebugMenu.register(title: "Pipeline: rewrite the test clip as a prompt in 5 s (Mode 2)") { [weak self] in
            self?.runClipProbe(mode: .prompt)
        }
        DebugMenu.register(title: "Pipeline: room tone, expect no API call") { [weak self] in
            self?.runSilenceProbe()
        }
        DebugMenu.register(title: "Pipeline: record live for 5 s, then dictate") { [weak self] in
            self?.runLiveProbe()
        }
    }

    private func runClipProbe(mode: DictationRecord.Mode) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                try await Task.sleep(for: Self.probeCountdown)
                let recording = try Self.recording(fromClipAt: Self.probeClipPath)
                let summary = String(
                    format: "%@ from the clip, %.2f s, %d level chunks",
                    mode.rawValue,
                    recording.duration,
                    recording.chunkRMS.count
                )
                self.logger.notice("probe: \(summary, privacy: .public)")
                self.pipeline?.runFromRecording(recording, mode: mode, target: FocusTarget.current())
            } catch {
                self.logger.error("probe failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func runSilenceProbe() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                try await Task.sleep(for: .seconds(1))
                let recording = try Self.silentRecording(seconds: 3)
                self.logger.notice("probe: room tone, \(recording.duration, privacy: .public) s")
                self.pipeline?.runFromRecording(recording, mode: .dictate, target: FocusTarget.current())
            } catch {
                self.logger.error("probe failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func runLiveProbe() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                try await Task.sleep(for: Self.probeCountdown)
                self.logger.notice("probe: live capture starting")
                self.pipeline?.startRequested()
                try await Task.sleep(for: .seconds(5))
                self.pipeline?.stopRequested()
            } catch {
                self.logger.error("probe failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Decodes a 16 kHz mono clip into the raw Float32 spool plus per-chunk RMS series that
    /// `AudioCapture` would have produced, so the pipeline runs against the same shapes it sees in
    /// real use.
    private static func recording(fromClipAt path: String) throws -> AudioCapture.Recording {
        guard FileManager.default.fileExists(atPath: path) else {
            throw PipelineProbeError.clipMissing(path)
        }

        let file = try AVAudioFile(forReading: URL(filePath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate == AudioCapture.sampleRate, format.channelCount == 1 else {
            throw PipelineProbeError.unexpectedClipFormat(
                sampleRate: format.sampleRate,
                channels: format.channelCount
            )
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw PipelineProbeError.clipUnreadable
        }
        try file.read(into: buffer)
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
            throw PipelineProbeError.clipUnreadable
        }

        let frameCount = Int(buffer.frameLength)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mydikte-probe-\(UUID().uuidString).pcm")
        try Data(bytes: samples, count: frameCount * MemoryLayout<Float>.size).write(to: url)

        return makeRecording(fileURL: url, samples: UnsafeBufferPointer(start: samples, count: frameCount))
    }

    /// Near-silence at about -80 dBFS: what a quiet room reads as, and what must never reach the API.
    private static func silentRecording(seconds: Double) throws -> AudioCapture.Recording {
        let frameCount = Int(seconds * AudioCapture.sampleRate)
        var samples = [Float](repeating: 0, count: frameCount)
        for index in samples.indices {
            samples[index] = Float.random(in: -0.0001...0.0001)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mydikte-probe-\(UUID().uuidString).pcm")
        try samples.withUnsafeBufferPointer { buffer in
            try Data(buffer: buffer).write(to: url)
        }

        return samples.withUnsafeBufferPointer { makeRecording(fileURL: url, samples: $0) }
    }

    /// 1360 frames is what the real converter emits per 4096-frame tap callback at this rate,
    /// measured in `evidence/step-08-format-probe.txt`, so the RMS series has the same granularity
    /// the VAD's thresholds were ported against.
    private static func makeRecording(
        fileURL: URL,
        samples: UnsafeBufferPointer<Float>
    ) -> AudioCapture.Recording {
        let chunkFrames = 1_360
        var chunkRMS: [Double] = []
        var index = samples.startIndex
        while index < samples.endIndex {
            let end = min(index + chunkFrames, samples.endIndex)
            var sum: Double = 0
            for offset in index..<end {
                sum += Double(samples[offset]) * Double(samples[offset])
            }
            chunkRMS.append((sum / Double(end - index)).squareRoot())
            index = end
        }

        let duration = Double(samples.count) / AudioCapture.sampleRate
        return AudioCapture.Recording(
            fileURL: fileURL,
            duration: duration,
            chunkRMS: chunkRMS,
            chunkSeconds: chunkRMS.isEmpty ? 0 : duration / Double(chunkRMS.count),
            coldStart: 0,
            wallClock: duration
        )
    }
}
