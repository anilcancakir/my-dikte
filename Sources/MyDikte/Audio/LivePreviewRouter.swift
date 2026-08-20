import AVFoundation
import Foundation

/// Routes the live preview to whichever backend `Settings.livePreviewProvider` names.
///
/// Written because the pipeline stops the preview on six different paths (normal stop, cancel, empty
/// capture, discard, transcription failure, teardown) and a two-backend branch at each of them is six
/// places for the two to drift apart. The choice lives in `start` and nowhere else.
///
/// `accept` and `stop` deliberately go to **both** backends rather than to the selected one. Each
/// begins with a single atomic load that returns immediately when that backend is not listening, so
/// the idle one costs a dictation nothing, and routing them would mean the audio tap reading a
/// mutable selection from the audio thread. `stop` is idempotent on both for the same reason.
final class LivePreviewRouter: @unchecked Sendable {
    private let apple = LivePreview()
    private let elevenLabs = ElevenLabsLivePreview()

    /// Set once during pipeline construction and delivered to both backends, so whichever one runs
    /// publishes through the same handler.
    var onPreviewText: (@MainActor @Sendable (String) -> Void)? {
        didSet {
            apple.onPreviewText = onPreviewText
            elevenLabs.onPreviewText = onPreviewText
        }
    }

    /// Starts the backend `provider` names, and returns the log line describing what happened.
    ///
    /// One string rather than the two backends' own `Readiness` types: the caller logs it and makes
    /// no decision on it, and a shared enum would have to carry both Apple's authorisation cases and
    /// ElevenLabs' missing-key case while meaning nothing to either.
    @discardableResult
    func start(
        provider: Settings.LivePreviewProvider,
        isEnabledInSettings: Bool,
        glossaryTerms: [String],
        language: String
    ) -> String {
        switch provider {
        case .apple:
            return apple.start(isEnabledInSettings: isEnabledInSettings).logMessage
        case .elevenLabs:
            return elevenLabs.start(
                isEnabledInSettings: isEnabledInSettings,
                glossaryTerms: glossaryTerms,
                language: language
            ).logMessage
        }
    }

    func stop() {
        apple.stop()
        elevenLabs.stop()
    }

    /// Ends the ElevenLabs stream and waits for the transcript of everything it was sent, so the
    /// socket that fed the preview produces the dictation and the audio is not uploaded again.
    ///
    /// Only the ElevenLabs backend can answer this; Apple's recogniser runs on device precisely so
    /// that its output can be thrown away, and its text has never been allowed near the caret. Apple
    /// is stopped here too, so one call ends the preview whichever backend was running.
    func finishAndAwaitRealtimeTranscript(timeout: Duration) async -> ElevenLabsLivePreview.TranscriptOutcome {
        apple.stop()
        return await elevenLabs.finishAndAwaitTranscript(timeout: timeout)
    }

    /// Called from the `AVAudioEngine` tap callback. Both calls are an atomic load and a return when
    /// that backend is idle.
    func accept(_ buffer: AVAudioPCMBuffer) {
        apple.accept(buffer)
        elevenLabs.accept(buffer)
    }
}
