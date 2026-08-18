import AppKit
import Foundation
import os

/// One dictation's worth of resolved settings, read once when recording starts so that a settings
/// change takes effect on the next dictation and never mid-flight.
///
/// It resolves two things `Settings` leaves open. An empty model id means "not configured", not
/// "send an empty model", so it falls back to the two models this plan actually measured. And the
/// chat endpoint has exactly two supported providers with exactly one Keychain account each
/// (`cleanup-groq`, `cleanup-openrouter`), so an endpoint that is still on `Settings`' untouched
/// default (`api.openai.com`, written before the plan's Wave 1 amendment moved cleanup to Groq)
/// resolves to Groq rather than authenticating against a key that cannot exist.
struct PipelineConfiguration: Sendable, Equatable {
    /// Measured on this machine at 0.38 to 0.66 s warm, and the more accurate model on Turkish
    /// (`evidence/step-02-groq-seam.txt`).
    static let defaultTranscriptionModelId = "whisper-large-v3"

    /// A starting default rather than a finished decision; the follow-on plan picks the winner from
    /// the log this pipeline writes.
    static let defaultCleanupModelId = "openai/gpt-oss-120b"

    /// The same Groq key serves both stages and both stages share one warm TLS connection.
    static let groqChatEndpoint = "https://api.groq.com/openai/v1/chat/completions"

    /// Raised from 768 after a real dictation lost its cleanup to this number.
    ///
    /// A 23-word Turkish transcript returned empty content in the app, and the same request measured
    /// directly spent **717, 596 and 580** completion tokens on three runs against a 768 budget. The
    /// answer itself is about 50 tokens; the rest is reasoning the reply never shows. So 768 was not
    /// generous, it was 51 tokens from the ceiling, and any run that thought slightly longer produced
    /// nothing at all. The floor now clears the worst observed reasoning by roughly twice over.
    ///
    /// Raising it is close to free: `max_tokens` is a ceiling and not a charge, so nothing is spent
    /// unless the model actually generates. The reason the budget is bounded at all is a runaway
    /// reply, which 2048 still prevents.
    static let minimumReplyTokens = 1536
    static let maximumReplyTokens = 3072

    /// Headroom for tokens the reply never shows. `openai/gpt-oss-120b` has no true "none" for
    /// reasoning effort, so it always thinks first and those tokens count against `max_tokens`.
    /// Measured twice, and the second measurement is why this doubled: a 22-word transcript with a
    /// 132-token budget came back HTTP 200 with empty `content`, and later a 23-word one did the same
    /// at 768 while spending up to 717 completion tokens on reasoning alone. Reasoning cost does not
    /// scale with input length the way the answer does, so this is a flat allowance and a large one.
    static let reasoningHeadroomTokens = 1024

    let provider: Settings.TranscriptionProvider
    let transcriptionModelId: String
    let cleanupModelId: String
    let glossaryTerms: [String]
    let autoInsert: Bool
    let retainAudio: Bool
    let historyLimit: Int
    let audioCuesEnabled: Bool
    let livePreviewEnabled: Bool
    let advisoryParaphraseGuard: Bool

    private let cleanupEndpoint: String
    private let rewriteEndpoint: String

    init(settings: Settings) {
        provider = settings.transcriptionProvider
        transcriptionModelId = Self.resolved(settings.transcriptionModelId, default: Self.defaultTranscriptionModelId)
        cleanupModelId = Self.resolved(settings.cleanupModelId, default: Self.defaultCleanupModelId)
        glossaryTerms = settings.glossaryTerms
        autoInsert = settings.autoInsert
        retainAudio = settings.retainAudio
        historyLimit = settings.historyLimit
        audioCuesEnabled = settings.audioCuesEnabled
        livePreviewEnabled = settings.livePreviewEnabled
        advisoryParaphraseGuard = settings.advisoryParaphraseGuard
        cleanupEndpoint = Self.resolvedEndpoint(settings.cleanupEndpoint)
        rewriteEndpoint = Self.resolvedEndpoint(settings.rewriteEndpoint)
    }

    /// What a paraphrase concern does to this dictation. Resolved here, with every other per-run
    /// decision, so a settings change takes effect on the next dictation and never mid-flight.
    func guardPolicy(for mode: DictationRecord.Mode) -> InsertionChoice.GuardPolicy {
        switch mode {
        case .prompt:
            return .skipped
        case .dictate:
            return advisoryParaphraseGuard ? .advisory : .strict
        }
    }

    func chatEndpoint(for mode: DictationRecord.Mode) -> String {
        switch mode {
        case .dictate:
            return cleanupEndpoint
        case .prompt:
            return rewriteEndpoint
        }
    }

    func chatKeychainAccount(for mode: DictationRecord.Mode) -> String {
        Self.chatKeychainAccount(forEndpoint: chatEndpoint(for: mode))
    }

    /// The account the configured endpoint's key lives under. Named per provider so switching
    /// endpoints never reads the other provider's key, which would fail with an authentication
    /// error that says nothing about the real cause.
    static func chatKeychainAccount(forEndpoint endpoint: String) -> String {
        endpoint.contains("openrouter.ai") ? "cleanup-openrouter" : "cleanup-groq"
    }

    /// Sized to the input rather than left open: an unbounded reply budget on a reasoning-capable
    /// model is how a cleanup call turns into a 90-second one. Six tokens per spoken word covers
    /// Turkish morphology plus the Mode 2 rewrite, which is legitimately longer than its input, and
    /// the headroom above covers the reasoning the reply never shows.
    static func maxTokens(forTranscript transcript: String) -> Int {
        let words = transcript.split(whereSeparator: { $0.isWhitespace }).count
        return min(maximumReplyTokens, max(minimumReplyTokens, words * 6 + reasoningHeadroomTokens))
    }

    private static func resolved(_ value: String, default fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// An empty endpoint means "use the default", exactly like an empty model id.
    ///
    /// This used to also rewrite any value equal to `Settings.default.cleanupEndpoint`, which was
    /// then an OpenAI URL. That made two different things indistinguishable: a field nobody had
    /// touched, and a user who had deliberately typed OpenAI. The untouched default won, so the
    /// pane displayed an OpenAI endpoint while every request went to Groq, and choosing OpenAI on
    /// purpose was impossible to express. The default is now empty, so a typed endpoint is honoured
    /// as typed.
    private static func resolvedEndpoint(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? groqChatEndpoint : trimmed
    }
}

/// What the cleanup or rewrite call came back with. A failure is a value here rather than a thrown
/// error, because the pipeline's rule is that a failed cleanup still inserts the dictation.
enum CleanupOutcome: Sendable, Equatable {
    case cleaned(String)
    case failed(reason: String)
}

/// What actually goes to the caret, and why, when it is not the cleaned text.
///
/// This is the rule dikte settled on at `references/dikte/dikte/worker.py:113-122`: the dictation is
/// never lost and the failure is never hidden. Both halves matter, and both live here rather than in
/// the pipeline's control flow, so they can be asserted without a network.
enum InsertionChoice: Sendable, Equatable {
    /// What the paraphrase guard's concern does to a dictation. Three states rather than a pair of
    /// booleans, because "skipped" and "advisory" cannot both be true and a Bool pair could say so.
    enum GuardPolicy: Sendable, Equatable {
        /// The Mode 2 rewrite. The guard compares a cleanup against the words it was given, and an
        /// English prompt rewritten from Turkish shares almost none of them by design, so running it
        /// there would reject every rewrite and insert the Turkish transcript instead, which is the
        /// opposite of what Mode 2 is for.
        case skipped
        /// The cleanup reaches the caret and the concern is surfaced beside it. The default, and it
        /// was chosen on measurement: over one day of real use the guard rejected three correct
        /// cleanups (a separated "ile", a repaired "Speech to Text", a repaired "optimize") and
        /// caught no genuine paraphrase, and every one of those cleanups was lost to the user.
        case advisory
        /// A concern discards the cleanup and the raw transcript goes in instead. The way back, kept
        /// reachable on purpose: advisory rests on a measurement, and a measurement can change.
        case strict
    }

    /// - Parameter concern: what the guard found, when it found something and the policy was
    ///   advisory. The cleaned text still reached the caret.
    case cleaned(text: String, concern: ParaphraseGuard.Concern?)
    /// - Parameter rejectedCleanup: the candidate the paraphrase guard turned down, kept so the
    ///   guard's own thresholds can be judged later against real dictations. `nil` when there was
    ///   never a candidate, which is the cleanup-failed case.
    /// - Parameter concern: what the guard found, or `nil` when the cleanup call itself failed and
    ///   the guard never ran.
    case raw(text: String, reason: String, rejectedCleanup: String?, concern: ParaphraseGuard.Concern?)

    static func resolve(
        raw: String,
        cleanup: CleanupOutcome,
        glossary: [String],
        guardPolicy: GuardPolicy
    ) -> InsertionChoice {
        switch cleanup {
        case .failed(let reason):
            // Untouched by the policy: advisory is only about the guard, and a cleanup that never
            // produced a candidate has nothing for the guard to have an opinion about.
            return .raw(
                text: raw,
                reason: "Cleanup failed, so the raw transcript went in: \(reason)",
                rejectedCleanup: nil,
                concern: nil
            )

        case .cleaned(let cleaned):
            guard guardPolicy != .skipped else {
                return .cleaned(text: cleaned, concern: nil)
            }
            guard
                case .concern(let concern) = ParaphraseGuard.check(
                    raw: raw,
                    cleaned: cleaned,
                    glossary: glossary
                )
            else {
                return .cleaned(text: cleaned, concern: nil)
            }

            guard guardPolicy == .strict else {
                return .cleaned(text: cleaned, concern: concern)
            }
            return .raw(
                text: raw,
                reason: "Raw transcript inserted instead: \(concern.sentence)",
                rejectedCleanup: cleaned,
                concern: concern
            )
        }
    }

    var text: String {
        switch self {
        case .cleaned(let text, _):
            return text
        case .raw(let text, _, _, _):
            return text
        }
    }

    /// The sentence to surface, at the indicator and in the log record's reason field, or `nil` when
    /// there is nothing to say. An advisory concern says its piece and the cleanup still went in, so
    /// it is prefixed rather than left to read as a substitution.
    var message: String? {
        switch self {
        case .cleaned(_, let concern):
            return concern.map { "Advisory: \($0.sentence)" }
        case .raw(_, let reason, _, _):
            return reason
        }
    }

    /// What the guard found, as data. The log carries this so that recurring terms can be counted
    /// (`GuardConcernLedger`) without any reader parsing `message`.
    var concern: ParaphraseGuard.Concern? {
        switch self {
        case .cleaned(_, let concern):
            return concern
        case .raw(_, _, _, let concern):
            return concern
        }
    }

    /// Whether the raw transcript went in where a cleanup was expected. That is the failure the user
    /// has to see as one; an advisory concern is not one, since the cleanup did reach the caret.
    var insertedRawInstead: Bool {
        switch self {
        case .cleaned:
            return false
        case .raw:
            return true
        }
    }

    /// The cleanup the paraphrase guard turned down, or `nil` when nothing was turned down.
    ///
    /// This is the artefact behind the reason string. The reason quotes word counts, which is enough
    /// to know that the guard fired and not enough to know whether it should have: a measured
    /// four-out-of-four rejection turned out to be the guard refusing the exact glossary repair the
    /// cleanup prompt asks for, and that was invisible from the log until the candidate was kept.
    /// Same argument the plan makes for keeping the raw transcript rather than collapsing the two
    /// API calls into one: keep the artefact, or the failure is undetectable by construction.
    ///
    /// In advisory mode it is `nil` even when there is a concern, because nothing was turned down.
    /// The cleanup is in `finalText`, where the user can read it.
    var rejectedCleanup: String? {
        switch self {
        case .cleaned:
            return nil
        case .raw(_, _, let rejectedCleanup, _):
            return rejectedCleanup
        }
    }
}

/// The orchestrator: it owns the state machine, the stage timing, the failure contract and the
/// wiring between the pieces Waves 1 to 3 built without any of them knowing about each other.
///
/// It also owns the live preview, and owns it at arm's length: the preview is started when recording
/// starts, stopped on every path a run can end on, and its text goes straight from `LivePreview` to
/// the indicator panel. Nothing on this type ever holds it, so `rawTranscript`, `finalText`, the
/// cleanup call, the paraphrase guard and the clipboard cannot see it. The authoritative transcript
/// is still Groq's, unchanged.
///
/// `@MainActor` because it drives the indicator, the audio cues and the status item. It reaches the
/// two non-main-actor layers only through their published APIs, and never into `AudioCapture`'s
/// locked state: the level series arrives with the finished `Recording`, and the live level arrives
/// through the capture's own `@Sendable` callback, which hops here with `Task { @MainActor in }`
/// (`evidence/step-08-09-17-swift6-probe.txt`).
@MainActor
final class DictationPipeline {
    /// Every stage transition, for the menu-bar icon. `AppDelegate` owns that mapping.
    var onStageChange: (PipelineStage) -> Void = { _ in }

    /// A failure the user has to know about. The panel and the cue carry it as well; this exists so
    /// the status item can show its error state. Never an alert: a modal for a pipeline failure
    /// would steal the focus the dictation just went to.
    var onFailure: (String) -> Void = { _ in }

    /// Whether a recording that only a command can end is in flight right now. `ShortcutCoordinator`
    /// listens, because this is the only thing that makes a bare Return or Space visible to this app:
    /// the pipeline is the sole authority on whether a dictation is running, since one can also end by
    /// cancel or by error.
    var onLatchedRecordingChange: (Bool) -> Void = { _ in }

    /// How the recording that is running now was started, which is what decides whether a bare Return
    /// or Space may end it.
    enum RecordingTrigger: Sendable, Equatable {
        /// The push-to-talk chord. The gesture ends when the keys come up, so nothing else needs to end
        /// it, and its modifiers are held throughout, which makes any Space pressed during it a
        /// modified press belonging to the focused application.
        case heldChord
        /// A keyed shortcut or the menu. The recording runs until something ends it, and a stop key is
        /// one of the things that may.
        case latched
    }

    private let capture = AudioCapture()
    private let indicator = IndicatorPanel()
    private let livePreview = LivePreview()
    private let logger = Logger(subsystem: BundleInfo.bundleIdentifier, category: "Pipeline")

    private var machine = PipelineStateMachine()
    private var processingTask: Task<Void, Never>?

    /// Cached across dictations so the second one reuses the TLS connection, worth about 37 ms
    /// measured. Rebuilt only when the provider or the model id changes.
    private var transcriptionClient: TranscriptionClient?
    private var transcriptionClientKey: String?

    private var configuration = PipelineConfiguration(settings: .load())
    private var requestedMode: DictationRecord.Mode = .dictate
    private var activeMode: DictationRecord.Mode = .dictate
    private var requestedTrigger: RecordingTrigger = .latched
    private var activeTrigger: RecordingTrigger = .latched
    /// What the shortcut layer was last told, so it hears a change and not every stage transition.
    private var isPublishedAsLatched = false
    private var focusTarget: FocusTarget?

    init() {
        // Registered before anything starts the engine: the tap captures the handler when it is
        // installed, so a handler set later would never be seen.
        capture.setLevelHandler { [weak self] level in
            // This runs on an AVFoundation render thread. Touching the main actor from there
            // directly is a SIGTRAP rather than a warning, so the hop is mandatory.
            Task { @MainActor in
                self?.indicator.update(level: level)
            }
        }
        // Also on the render thread, and `accept` is written for it: it copies into a preallocated
        // slot and wakes its own queue. No hop here, because a hop would have to allocate on the
        // audio thread to make one.
        capture.setBufferSink { [livePreview] buffer in
            livePreview.accept(buffer)
        }
        // The preview text goes to the panel and nowhere else. It is never stored on this type, so
        // there is no path from it to the caret, the clipboard, the cleanup call or the log.
        livePreview.onPreviewText = { [weak self] text in
            self?.indicator.update(previewText: text)
        }
    }

    var stage: PipelineStage {
        machine.stage
    }

    // MARK: - The shortcut surface

    /// The chord's first modifier went down. This is the half of Wave 2 that was left unconnected:
    /// `ShortcutCoordinator` reports the press, `AudioCapture` pays a measured 154 ms cold start,
    /// and the 150 to 300 ms human gap before the second modifier is what covers it.
    func warmUpRequested() {
        perform(machine.handle(.warmUpRequested))
    }

    func warmUpAbandoned() {
        perform(machine.handle(.warmUpAbandoned))
    }

    /// - Parameter trigger: how this recording is being started, which decides whether a bare Return or
    ///   Space may end it. The chord passes `.heldChord`; the menu and the debug probes take the
    ///   default, because a recording nobody is holding a key for has to be endable by something.
    func startRequested(mode: DictationRecord.Mode = .dictate, trigger: RecordingTrigger = .latched) {
        requestedMode = mode
        requestedTrigger = trigger
        perform(machine.handle(.startRequested))
    }

    func stopRequested() {
        perform(machine.handle(.stopRequested))
    }

    /// The keyed toggle. `mode` only applies when this press starts a dictation; a press that stops
    /// one keeps the mode the running dictation began with.
    ///
    /// Always latched: this shortcut is a key pressed and released, so nothing is being held that could
    /// end the recording on its own.
    func toggleRequested(mode: DictationRecord.Mode = .dictate) {
        requestedMode = mode
        requestedTrigger = .latched
        perform(machine.handle(.toggleRequested))
    }

    func cancelRequested() {
        perform(machine.handle(.cancelRequested))
    }

    /// Debug-menu only: runs everything after the microphone from an already-captured recording.
    /// It is how the whole chain (VAD, encode, transcribe, filter, cleanup, guard, insert, log) is
    /// driven without a keyboard and without a voice, which is the only way this step can be
    /// verified by anything other than a human at the machine.
    func runFromRecording(_ recording: AudioCapture.Recording, mode: DictationRecord.Mode, target: FocusTarget?) {
        guard machine.stage == .idle else {
            logger.notice("QA run refused: a dictation is already in flight")
            return
        }

        configuration = PipelineConfiguration(settings: .load())
        _ = machine.handle(.startRequested)
        _ = machine.handle(.stopRequested)
        indicator.beginRun(stage: machine.stage)
        publishStage()
        // The same pre-warm a real recording opens, and this is the harshest case for it: a fixture run
        // has no seconds of speech to hide the handshake in, so it only helps if it finishes inside the
        // encode and transcribe window. That makes it measurable without a voice, which is the only way
        // the pre-warm can be measured at all.
        prewarmChatConnection(mode: mode, configuration: configuration)
        beginProcessing(mode: mode, target: target, preCaptured: recording)
    }

    // MARK: - Carrying out what the table decided

    private func perform(_ action: PipelineStateMachine.Action) {
        switch action {
        case .doNothing:
            break
        case .warmUpCapture:
            warmUpCapture()
        case .cancelWarmUp:
            capture.cancelWarmUp()
            livePreview.stop()
        case .beginRecording:
            beginRecording()
        case .stopAndProcess:
            beginProcessing(mode: activeMode, target: focusTarget, preCaptured: nil)
        case .discardRecording:
            // Same engine and same spool as a warm-up, so this is also the discard path.
            capture.cancelWarmUp()
            livePreview.stop()
            indicator.endRun(message: "Cancelled")
        case .abortWork:
            // The in-flight request unwinds through its own cancellation path and reports from
            // there, so this only has to ask.
            processingTask?.cancel()
        }
        publishStage()
    }

    private func warmUpCapture() {
        do {
            try capture.warmUp()
        } catch {
            // The machine believes the engine is warm, so it has to be told otherwise before the
            // failure is reported; otherwise the next press would think a warm-up is already open.
            _ = machine.handle(.warmUpAbandoned)
            capture.cancelWarmUp()
            report(failure: error.localizedDescription)
        }
    }

    private func beginRecording() {
        // Read once per dictation: a key or a glossary term entered in Settings takes effect on the
        // next dictation without a restart, and never changes underneath a running one.
        configuration = PipelineConfiguration(settings: .load())
        activeMode = requestedMode
        activeTrigger = requestedTrigger
        // Captured now rather than when the text is ready: the round trip is long enough for the
        // user to glance at another window, and pasting into that window is how a dictation lands
        // in the wrong app.
        focusTarget = FocusTarget.current()

        do {
            try capture.beginKeeping()
        } catch {
            _ = machine.handle(.runEnded)
            report(failure: error.localizedDescription)
            return
        }

        indicator.beginRun(stage: .recording)
        AudioCue.play(.recordStart, enabled: configuration.audioCuesEnabled)
        // After the capture is up and after the cue, so nothing about the preview can sit between
        // the shortcut and the first recorded buffer. It reports why there is no preview to the log
        // and returns; there is no failure path from here into the dictation.
        livePreview.start(isEnabledInSettings: configuration.livePreviewEnabled)
        // Last, and off this actor entirely: the recording is already running by the time the
        // handshake starts.
        prewarmChatConnection(mode: activeMode, configuration: configuration)
    }

    /// Opens the connection the cleanup or rewrite call will reuse, while the user is still speaking.
    ///
    /// Measured, and the reason it exists: transcription warms `api.groq.com`, and cleanup now goes to
    /// `openrouter.ai`, a second host whose DNS lookup and TLS handshake the dictation used to pay for
    /// on the critical path. A recording lasts seconds and the host is known the moment it starts, so
    /// the handshake is paid during the recording instead of after the transcription.
    ///
    /// Detached, and nothing waits for it: it must not delay the start of recording, must not write
    /// anything to the caret, and must not be able to fail a dictation, so its outcome is a logged
    /// value rather than a thrown error. It also carries no API key and cannot produce a completion,
    /// which would cost tokens against a rate limit the user is already close to.
    private func prewarmChatConnection(mode: DictationRecord.Mode, configuration: PipelineConfiguration) {
        let endpoint: String = configuration.chatEndpoint(for: mode)
        let logger: Logger = self.logger

        Task.detached(priority: .userInitiated) {
            switch await ChatClient.prewarm(endpoint: endpoint) {
            case .opened(let host, let duration):
                // Logged as a number rather than a fact: this is the handshake the dictation no longer
                // pays for, so it is the measurement of what the pre-warm is worth.
                let milliseconds: Double = StageTimings.seconds(duration) * 1000
                logger.notice(
                    """
                    pre-warmed \(host, privacy: .public) in \
                    \(String(format: "%.0f", milliseconds), privacy: .public) ms
                    """
                )
            case .skipped(let reason):
                logger.notice("cleanup connection pre-warm skipped: \(reason, privacy: .public)")
            case .failed(let host, let reason):
                // Logged and otherwise ignored: the real request will open its own connection, so a
                // failed pre-warm costs latency and never a dictation.
                logger.error(
                    "cleanup connection pre-warm to \(host, privacy: .public) failed: \(reason, privacy: .public)"
                )
            }
        }
    }

    private func beginProcessing(
        mode: DictationRecord.Mode,
        target: FocusTarget?,
        preCaptured: AudioCapture.Recording?
    ) {
        let configuration = self.configuration
        // The handle is deliberately not cleared when the run ends. Clearing it would happen after
        // the await resumes, which is a suspension point the next dictation can start inside, and
        // the finished run would then null out the new run's handle and make cancel a no-op.
        // Cancelling an already-finished task is harmless, so keeping the stale handle is the safe
        // side of that trade.
        processingTask = Task { [weak self] in
            await self?.run(mode: mode, target: target, configuration: configuration, preCaptured: preCaptured)
        }
    }

    // MARK: - The run

    private func run(
        mode: DictationRecord.Mode,
        target: FocusTarget?,
        configuration: PipelineConfiguration,
        preCaptured: AudioCapture.Recording?
    ) async {
        // Monotonic, not wall time: `totalMs` is measured from shortcut release to insertion
        // complete, which is the number the user experiences and the one the Definition of Done
        // asserts against 1.5 s. A clock change mid-dictation must not move it.
        let releasedAt = ContinuousClock.now
        let timestamp = Date()
        var timings = StageTimings()
        var temporaryFiles: [URL] = []
        // Declared out here so the failure path can say how much audio actually reached the model.
        // A rejection quoting only a log-probability tells the user nothing they can act on, and the
        // commonest cause of one is a hold that was too short once the Bluetooth lead-in came off.
        var sentAudioSeconds: Double = 0

        do {
            // 1. Finish the capture and take the per-chunk level series with it.
            let recording: AudioCapture.Recording
            if let preCaptured {
                recording = preCaptured
            } else {
                // Before the capture stops, so the preview stops hearing at the same instant the
                // recording does, and before the clock starts, so an atomic exchange and one async
                // dispatch cannot land in `captureMs`. The teardown runs on the preview's own queue
                // and nothing here waits for it.
                livePreview.stop()
                let started = ContinuousClock.now
                recording = try capture.stop()
                timings.record(.capture, seconds: Self.elapsed(since: started))
            }
            temporaryFiles.append(recording.fileURL)

            // 2. Room tone: discard, say what was measured, and make no API call at all. The
            //    absence of a `transcribeMs` in the logged record is what proves none was made.
            //
            //    An empty capture is checked first and reported separately. Feeding it to the
            //    analyser is not wrong, but the analyser answers "how loud was it" and an empty
            //    series has no answer, so it returns its -120 dB floor and the user reads a
            //    measurement that was never taken.
            let analysis = VoiceActivity.analyse(
                rmsValues: recording.chunkRMS,
                chunkSeconds: recording.chunkSeconds
            )
            let emptyCapture = Self.emptyCaptureReason(
                chunkCount: recording.chunkRMS.count,
                heldSeconds: recording.duration
            )
            if emptyCapture != nil || VoiceActivity.isSilent(analysis) {
                let message = emptyCapture ?? String(
                    format: "No speech detected (peak %.0f dB, %.1f s voiced).",
                    analysis.speechPeakDB,
                    analysis.voicedSeconds
                )
                remove(temporaryFiles)
                appendRecord(
                    timestamp: timestamp,
                    mode: mode,
                    audioPath: nil,
                    duration: recording.duration,
                    rawTranscript: "",
                    finalText: "",
                    reason: message,
                    timings: timings.record(totalSeconds: Self.elapsed(since: releasedAt)),
                    configuration: configuration
                )
                finish(message: message, isFailure: false)
                return
            }

            // 3. Encode to m4a, off the main actor: it is a file read plus an AAC encode, and the
            //    upload size is the largest lever in the network path.
            let pcmURL = recording.fileURL
            let m4aURL = pcmURL.deletingPathExtension().appendingPathExtension("m4a")
            temporaryFiles.append(m4aURL)
            // Dead air at the head is dropped here rather than sent. A Bluetooth microphone delivers
            // exact zeros for about a second and a half while its link opens, and Whisper answers
            // leading digital silence by inventing a stock caption instead of transcribing: a real
            // 8.14 s dictation came back as "İzlediğiniz için teşekkürler." and the same samples with
            // 1.85 s trimmed came back as the sentence the user actually said.
            let leadingSilence: Double = LeadingSilence.secondsToTrim(
                chunkRMS: recording.chunkRMS,
                chunkSeconds: recording.chunkSeconds
            )
            if leadingSilence > 0 {
                logger.notice(
                    "trimming \(String(format: "%.2f", leadingSilence), privacy: .public) s of leading silence"
                )
            }
            sentAudioSeconds = max(0, recording.duration - leadingSilence)
            let encodeStarted = ContinuousClock.now
            let audioData: Data = try await Task.detached(priority: .userInitiated) {
                try AudioEncoder.encodeM4A(
                    pcmFileURL: pcmURL,
                    to: m4aURL,
                    skippingLeadingSeconds: leadingSilence
                )
                // Only readable once `encodeM4A` has returned: the container index is written when
                // its `AVAudioFile` deinits, which is at the end of that call.
                return try Data(contentsOf: m4aURL)
            }.value
            timings.record(.encode, seconds: Self.elapsed(since: encodeStarted))
            remove([pcmURL])
            temporaryFiles.removeAll { $0 == pcmURL }
            try Task.checkCancellation()

            // 4. Transcribe.
            advance(to: .transcribing)
            let transcribeStarted = ContinuousClock.now
            let transcription = try await client(for: configuration).transcribe(
                audioData: audioData,
                glossaryTerms: configuration.glossaryTerms
            )
            timings.record(.transcribe, seconds: Self.elapsed(since: transcribeStarted))
            let raw = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.notice("transcribed \(raw.count, privacy: .public) characters")

            // 5. A stock phrase invented for a near-silent clip never reaches the caret.
            // Voiced seconds, not wall-clock duration. The filter's premise is about how much real
            // audio the model had, and wall clock is not that: a real 8.14 s dictation whose first
            // 1.85 s was a Bluetooth link opening came back as the stock phrase
            // "İzlediğiniz için teşekkürler.", which is in the filter's list, and skipped the check
            // entirely because 8.14 s is past the six second cut-off. Voiced seconds is the variable
            // the premise actually names.
            if let discardReason = Self.discardReason(
                forTranscript: raw,
                duration: analysis.voicedSeconds
            ) {
                remove(temporaryFiles)
                appendRecord(
                    timestamp: timestamp,
                    mode: mode,
                    audioPath: nil,
                    duration: recording.duration,
                    rawTranscript: raw,
                    finalText: "",
                    reason: discardReason,
                    timings: timings.record(totalSeconds: Self.elapsed(since: releasedAt)),
                    configuration: configuration
                )
                finish(message: discardReason, isFailure: false)
                return
            }

            // 6. Clean up, or rewrite into an English prompt. A failure here is a value, not a
            //    throw: the dictation still goes in.
            advance(to: mode == .dictate ? .cleaning : .rewriting)
            let cleanupStarted = ContinuousClock.now
            let outcome = try await cleanupOutcome(raw: raw, mode: mode, configuration: configuration)
            timings.record(.cleanup, seconds: Self.elapsed(since: cleanupStarted))

            // 7. The paraphrase guard, and the decision about what actually gets inserted.
            let choice = InsertionChoice.resolve(
                raw: raw,
                cleanup: outcome,
                glossary: configuration.glossaryTerms,
                guardPolicy: configuration.guardPolicy(for: mode)
            )
            if let concern = choice.concern {
                // The term is a single dictated word and it is logged in the clear on purpose: it is
                // the only way to see from outside the app which terms the guard keeps flagging, and
                // the transcript itself already sits in `log.jsonl` beside it.
                logger.notice(
                    """
                    guard concern \(concern.kind.rawValue, privacy: .public) \
                    term \(concern.term ?? "none", privacy: .public) \
                    inserted \(choice.insertedRawInstead ? "raw" : "cleanup", privacy: .public)
                    """
                )
            }

            // 8. Insert. The cancellation check is here rather than only inside the clients,
            //    because a cancel that lands between the last response and the paste must still
            //    leave nothing behind.
            try Task.checkCancellation()
            advanceToInserting()
            let insertStarted = ContinuousClock.now
            let insertionNote = try await insert(choice.text, into: target, configuration: configuration)
            timings.record(.insert, seconds: Self.elapsed(since: insertStarted))

            // 9. The record and every stage timing, plus the audio when retention is on.
            let audioPath = retainedAudioPath(m4aURL, timestamp: timestamp, configuration: configuration)
            remove(temporaryFiles)
            appendRecord(
                timestamp: timestamp,
                mode: mode,
                audioPath: audioPath,
                duration: recording.duration,
                rawTranscript: raw,
                finalText: choice.text,
                reason: choice.message,
                rejectedCleanup: choice.rejectedCleanup,
                guardConcern: choice.concern,
                timings: timings.record(totalSeconds: Self.elapsed(since: releasedAt)),
                configuration: configuration
            )

            // 10. The cue fires on a completed insertion, including one that inserted the raw
            //     transcript: the text did land. The reason still shows, because a failure that is
            //     not surfaced looks exactly like working dictation.
            //
            //     An advisory concern is surfaced the same way and is deliberately not a failure:
            //     the cleanup reached the caret, so the status item stays out of its error state and
            //     only the panel carries the note.
            if let insertionNote {
                finish(message: insertionNote, isFailure: true)
            } else {
                AudioCue.play(.insertComplete, enabled: configuration.audioCuesEnabled)
                finish(message: choice.message, isFailure: choice.insertedRawInstead)
            }
        } catch is CancellationError {
            remove(temporaryFiles)
            finish(message: "Cancelled", isFailure: false)
        } catch {
            // A transcript the quality gate turned down still gets a log line, carrying the text and
            // the numbers that rejected it. Every other failure has no transcript to record: there is
            // no text, so a record would hold only the reason the log already shows on the next
            // successful line. This branch exists because a real rejection reached the user as one
            // sentence and left nothing behind, so the threshold that produced it could not be
            // checked against anything.
            var message: String = error.localizedDescription
            if case ProviderError.lowQualityTranscript(let reason, let transcript) = error {
                let advice: String = Self.shortAudioAdvice(seconds: sentAudioSeconds)
                message = "\(error.localizedDescription)\(advice)"
                appendRecord(
                    timestamp: timestamp,
                    mode: mode,
                    audioPath: nil,
                    duration: sentAudioSeconds,
                    rawTranscript: transcript,
                    finalText: "",
                    reason: "Transcription rejected by the quality gate: \(reason)\(advice)",
                    timings: timings.record(totalSeconds: Self.elapsed(since: releasedAt)),
                    configuration: configuration
                )
            }
            remove(temporaryFiles)
            finish(message: message, isFailure: true)
        }
    }

    /// Runs the mode's chat call. Only cancellation propagates; every other failure comes back as
    /// `.failed`, because losing the dictation is worse than losing the cleanup.
    private func cleanupOutcome(
        raw: String,
        mode: DictationRecord.Mode,
        configuration: PipelineConfiguration
    ) async throws -> CleanupOutcome {
        let messages = PromptAssembly.messages(
            for: mode == .dictate ? .cleanup : .promptRewrite,
            transcript: raw,
            glossary: configuration.glossaryTerms
        )
        let client = ChatClient(
            endpoint: configuration.chatEndpoint(for: mode),
            apiKeyAccount: configuration.chatKeychainAccount(for: mode),
            modelId: configuration.cleanupModelId
        )

        do {
            let reply = try await client.complete(
                messages: messages,
                maxTokens: PipelineConfiguration.maxTokens(forTranscript: raw)
            )
            return .cleaned(reply.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            // A cancelled request is not a cleanup failure: it must insert nothing at all.
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            logger.error("cleanup failed: \(error.localizedDescription, privacy: .public)")
            return .failed(
                reason: error.localizedDescription
                    + Self.thinTranscriptAdvice(transcript: raw, mode: mode, error: error)
            )
        }
    }

    /// Puts `text` where the user can use it, and returns the note to show when that was not the
    /// caret. Returning a note rather than throwing keeps the log append on the success path: the
    /// dictation happened either way and must be recorded.
    private func insert(
        _ text: String,
        into target: FocusTarget?,
        configuration: PipelineConfiguration
    ) async throws -> String? {
        guard configuration.autoInsert else {
            try TextInserter.write(text, to: .general)
            return "Auto-insert is off, so the text is on the clipboard."
        }
        guard let target else {
            try TextInserter.write(text, to: .general)
            return "No application was frontmost when recording started, so the text is on the clipboard."
        }

        do {
            try await TextInserter.insert(text, into: target)
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Every `InsertionError` leaves the text on the clipboard by construction, and its own
            // message says so, so this is reported rather than retried.
            return error.localizedDescription
        }
    }

    // MARK: - Stage reporting

    private func advance(to activity: PipelineStage.Activity) {
        _ = machine.handle(.activityChanged(activity))
        publishStage()
    }

    private func advanceToInserting() {
        _ = machine.handle(.insertionStarted)
        publishStage()
    }

    private func publishStage() {
        let stage = machine.stage
        if stage.isBusy {
            indicator.update(stage: stage)
        }
        onStageChange(stage)
        publishLatchedRecording(for: stage)
    }

    /// Tells the shortcut layer whether a bare Return or Space may end what is running now.
    ///
    /// Derived from the stage in one place rather than announced on each path a run can end on. There
    /// are seven of those, and a missed one would leave the two keys swallowed after the recording was
    /// over, which is the one failure this feature must not have.
    private func publishLatchedRecording(for stage: PipelineStage) {
        let isLatched: Bool = Self.isLatchedRecording(stage: stage, trigger: activeTrigger)
        guard isLatched != isPublishedAsLatched else {
            return
        }

        isPublishedAsLatched = isLatched
        onLatchedRecordingChange(isLatched)
    }

    /// Whether a bare Return or Space may end the recording these two values describe.
    ///
    /// A latched recording is one that runs until something ends it, which is a keyed shortcut's or the
    /// menu's. The chord is excluded because releasing it already ends the gesture, and every stage
    /// other than `recording` is excluded because the keys are watched for the seconds a recording
    /// lasts and not a moment longer.
    nonisolated static func isLatchedRecording(stage: PipelineStage, trigger: RecordingTrigger) -> Bool {
        stage == .recording && trigger == .latched
    }

    private func finish(message: String?, isFailure: Bool) {
        // The backstop, not the primary: a run that reached its audio has already stopped the preview
        // above, and this covers anything that ends some other way, including a failure thrown before
        // that point. `stop()` is idempotent, so the normal path pays one atomic exchange here.
        livePreview.stop()
        _ = machine.handle(.runEnded)
        indicator.endRun(message: message)
        publishStage()

        guard isFailure, let message else {
            return
        }
        logger.error("dictation reported a failure: \(message, privacy: .public)")
        onFailure(message)
    }

    /// A failure with no run behind it (a warm-up that could not start, a capture that never
    /// began). Same channel as `finish`, minus the state transition.
    private func report(failure message: String) {
        livePreview.stop()
        indicator.endRun(message: message)
        logger.error("\(message, privacy: .public)")
        onFailure(message)
    }

    // MARK: - Pieces the run leans on

    private func client(for configuration: PipelineConfiguration) -> TranscriptionClient {
        let key = "\(configuration.provider.rawValue)|\(configuration.transcriptionModelId)"
        if key == transcriptionClientKey, let transcriptionClient {
            return transcriptionClient
        }

        let provider: any TranscriptionProvider
        switch configuration.provider {
        case .groq:
            provider = GroqTranscriptionProvider(modelId: configuration.transcriptionModelId)
        case .openAI:
            provider = OpenAITranscriptionProvider(modelId: configuration.transcriptionModelId)
        case .openRouter:
            provider = OpenRouterTranscriptionProvider(modelId: configuration.transcriptionModelId)
        }

        let client = TranscriptionClient(provider: provider)
        transcriptionClient = client
        transcriptionClientKey = key
        return client
    }

    /// What to add to an empty cleanup response so it says something the user can act on.
    ///
    /// Measured, and the reason this exists: a Mode 2 attempt failed with "The cleanup endpoint
    /// returned no message content", which reads like a provider outage and was not one. The hold was
    /// 3.3 s, 1.6 s of it a Bluetooth link opening, so 1.7 s of audio produced the transcript "Ben
    /// olacak görelim." and the model had nothing to rewrite into a prompt. The same system prompt and
    /// the same 768-token budget turned a real request into a full structured English prompt on the
    /// first try, so the feature was working and the input was not there.
    ///
    /// Only the empty-response case is annotated. A network error or an HTTP status says what it is,
    /// and appending guesses about length to those would be noise.
    nonisolated static func thinTranscriptAdvice(
        transcript: String,
        mode: DictationRecord.Mode,
        error: Error
    ) -> String {
        guard case ChatClient.ChatClientError.emptyResponse = error else {
            return ""
        }

        let words: Int = transcript.split(whereSeparator: { $0.isWhitespace }).count
        guard words < thinTranscriptWords else {
            return ""
        }
        guard mode == .prompt else {
            return " The transcript was only \(words) word(s), which may be too little to clean up."
        }
        return " The transcript was only \(words) word(s), which is usually the reason: Mode 2 rewrites "
            + "what you said into a prompt, and it needs a real request to work from. Hold for longer, "
            + "and with a Bluetooth microphone leave a beat after pressing before you speak."
    }

    /// Below this many words, an empty rewrite is far more likely to be a thin transcript than a
    /// provider fault. The measured failure had three.
    private nonisolated static let thinTranscriptWords: Int = 8

    /// What to add to a quality-gate rejection so it says something the user can act on.
    ///
    /// The gate reports a log-probability, which is the right thing to record and the wrong thing to
    /// show on its own. Measured on a real Mode 2 attempt: a 3.5 s hold, 1.13 s of it a Bluetooth link
    /// opening, left 2.4 s of audio, and the model returned four unlikely words at an `avg_logprob` of
    /// -1.64 against a -1.0 limit. The number was correct and unactionable; the length was the cause.
    nonisolated static func shortAudioAdvice(seconds: Double) -> String {
        guard seconds > 0 else {
            return ""
        }
        let measured = String(format: "%.1f", seconds)
        guard seconds < shortAudioSeconds else {
            return " Audio sent: \(measured) s."
        }
        return " Only \(measured) s of audio reached the model, which is usually the reason: hold for "
            + "longer, and with a Bluetooth microphone leave a beat after pressing before you speak."
    }

    /// Below this, a rejection is far more likely to be a short hold than a bad model.
    private nonisolated static let shortAudioSeconds: Double = 4.0

    /// Why this capture cannot be analysed at all, or `nil` when it produced audio.
    ///
    /// Zero buffers is not silence, and the two need different messages because they need different
    /// fixes: silence means speak up or check the room, zero buffers means the input device never
    /// started delivering. Measured on this machine, which is why this branch exists: the built-in
    /// microphone's first buffer lands 156 ms after `engine.start()`, while AirPods as the input
    /// device produced **0 frames** across a 1.4 s push-to-talk hold and then captured 5.23 s
    /// normally when given a 5 s window. Bluetooth opens its microphone link about a second after
    /// the engine starts, so a short hold can end before the first buffer ever arrives, and the
    /// user reads "No speech detected (peak -120 dB)" and goes looking for a microphone fault that
    /// is not there. -120 dB is the analyser's floor for an empty series, not a measurement.
    ///
    /// Past a few seconds the Bluetooth advice stops being true and would be misleading, so a long
    /// hold that still produced nothing is reported as the plain fault it is.
    /// `nonisolated` because it reads nothing but its arguments: the enclosing type is `@MainActor`
    /// for the indicator and the cues, and a pure decision has no reason to inherit that.
    nonisolated static func emptyCaptureReason(chunkCount: Int, heldSeconds: Double) -> String? {
        guard chunkCount == 0 else {
            return nil
        }

        let held = String(format: "%.1f", heldSeconds)
        guard heldSeconds < Self.bluetoothWarmUpAdviceSeconds else {
            return "The input device delivered no audio in \(held) s. Check that the right "
                + "microphone is selected in System Settings, Sound, Input."
        }
        return "The input device delivered no audio in \(held) s. A Bluetooth microphone such as "
            + "AirPods takes about a second to open its link, so hold the chord longer, or use the "
            + "toggle shortcut, which has no hold requirement at all."
    }

    /// Above this hold, blaming a Bluetooth link's start-up time is no longer credible.
    private nonisolated static let bluetoothWarmUpAdviceSeconds: Double = 4.0

    /// Why this transcript must not reach the caret, or `nil` when it may.
    private static func discardReason(forTranscript raw: String, duration: TimeInterval) -> String? {
        if raw.isEmpty {
            return "The transcript came back empty, so nothing was inserted."
        }
        guard HallucinationFilter.looksLikeHallucination(text: raw, duration: duration) else {
            return nil
        }
        return "Discarded a stock phrase: \"\(raw.prefix(60))\""
    }

    private func appendRecord(
        timestamp: Date,
        mode: DictationRecord.Mode,
        audioPath: URL?,
        duration: Double,
        rawTranscript: String,
        finalText: String,
        reason: String?,
        rejectedCleanup: String? = nil,
        guardConcern: ParaphraseGuard.Concern? = nil,
        timings: DictationRecord.Timings,
        configuration: PipelineConfiguration
    ) {
        let record = DictationRecord(
            timestamp: timestamp,
            mode: mode,
            audioPath: audioPath,
            duration: duration,
            rawTranscript: rawTranscript,
            finalText: finalText,
            // The log's one free-text reason field. It carries a paraphrase rejection, a cleanup
            // failure or a discard reason, all of which answer the same question an offline reader
            // asks: why is `finalText` not the cleaned transcript.
            paraphraseRejectionReason: reason,
            rejectedCleanup: rejectedCleanup,
            guardConcern: guardConcern,
            transcriptionModelId: configuration.transcriptionModelId,
            cleanupModelId: configuration.cleanupModelId,
            timings: timings
        )

        do {
            try DictationLog.append(record)
            try DictationLog.trim(to: configuration.historyLimit)
        } catch {
            // The dictation already reached the caret, so this is not a failed dictation; it is
            // still logged loudly, because a silent log failure is what would make the follow-on
            // plan's offline replay quietly incomplete.
            logger.error("could not write the dictation log: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func retainedAudioPath(
        _ audioURL: URL,
        timestamp: Date,
        configuration: PipelineConfiguration
    ) -> URL? {
        guard configuration.retainAudio else {
            return nil
        }
        do {
            return try DictationLog.retainAudio(from: audioURL, timestamp: timestamp)
        } catch {
            logger.error("could not retain the dictation audio: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func remove(_ urls: [URL]) {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                logger.warning("could not remove \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func elapsed(since instant: ContinuousClock.Instant) -> Double {
        StageTimings.seconds(instant.duration(to: ContinuousClock.now))
    }
}
