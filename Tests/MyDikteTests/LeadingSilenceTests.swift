import Foundation
import Testing

@testable import MyDikte

/// The measured failure this exists for, from a real dictation on 2026-08-18.
///
/// The user spoke for 8.14 s with AirPods as the input device. Groq returned
/// `"İzlediğiniz için teşekkürler."`, one of Whisper's stock Turkish YouTube phrases, and it passed the
/// hallucination filter and reached the caret. The audio was fine: peak -3.0 dBFS, zero-crossing rate
/// 0.103 and lag-1 autocorrelation 0.987, all squarely speech. What was wrong was the head of it.
/// A Bluetooth microphone link opens about a second and a half after the engine starts, and until it
/// does the tap delivers **exact zeros**, which were spooled and sent.
///
/// Trimming that 1.85 s of absolute silence and re-sending the identical audio returned
/// `"Bundan beri baktığım işlerin hiçbirinde bir değişiklik olmadığı için ben deploy yapmayı denedim."`
/// So the dictation was never lost; leading digital silence made Whisper invent a caption instead of
/// transcribing. Detail in `evidence/step-08-bluetooth-cold-start.txt`.
@Suite("LeadingSilence")
struct LeadingSilenceTests {
    /// One 8192-frame chunk at 16 kHz, the shape `AudioCapture.Recording.chunkSeconds` reports.
    private static let chunkSeconds = 0.085

    @Test("audio that starts with speech is not trimmed at all")
    func speechFromTheStartIsNotTrimmed() {
        let trimmed = LeadingSilence.secondsToTrim(
            chunkRMS: [0.04, 0.06, 0.05, 0.03],
            chunkSeconds: Self.chunkSeconds
        )
        #expect(trimmed == 0)
    }

    @Test("a run of exact zeros at the head is trimmed, keeping a pre-roll")
    func leadingDigitalSilenceIsTrimmed() {
        // 22 silent chunks is about 1.87 s, the measured AirPods case.
        let chunks = Array(repeating: 0.0, count: 22) + Array(repeating: 0.05, count: 60)
        let trimmed = LeadingSilence.secondsToTrim(chunkRMS: chunks, chunkSeconds: Self.chunkSeconds)

        #expect(trimmed > 1.5)
        // The pre-roll keeps the trim short of the first voiced chunk, so a soft onset survives.
        #expect(trimmed < 22 * Self.chunkSeconds)
    }

    @Test("a short lead-in is left alone, since trimming it buys nothing and risks the onset")
    func shortLeadInIsLeftAlone() {
        // Two chunks is about 170 ms, the built-in microphone's measured 156 ms cold start.
        let chunks = [0.0, 0.0] + Array(repeating: 0.05, count: 40)
        #expect(LeadingSilence.secondsToTrim(chunkRMS: chunks, chunkSeconds: Self.chunkSeconds) == 0)
    }

    @Test("a recording that is silent throughout is not trimmed, so the VAD still sees it")
    func fullySilentRecordingIsNotTrimmed() {
        let trimmed = LeadingSilence.secondsToTrim(
            chunkRMS: Array(repeating: 0.0, count: 40),
            chunkSeconds: Self.chunkSeconds
        )
        #expect(trimmed == 0)
    }

    /// Room tone is not digital silence, and the distinction is the whole point: a Bluetooth link that
    /// has not opened delivers exact zeros, while a quiet room delivers a noise floor. Trimming on a
    /// noise-floor threshold would eat the start of quiet speech.
    @Test("a quiet noise floor is not treated as silence")
    func roomToneIsNotTrimmed() {
        let chunks = Array(repeating: 0.0008, count: 22) + Array(repeating: 0.05, count: 60)
        #expect(LeadingSilence.secondsToTrim(chunkRMS: chunks, chunkSeconds: Self.chunkSeconds) == 0)
    }

    @Test("the trim is capped, so a long dead lead-in cannot swallow the recording")
    func trimIsCapped() {
        let chunks = Array(repeating: 0.0, count: 200) + Array(repeating: 0.05, count: 20)
        let trimmed = LeadingSilence.secondsToTrim(chunkRMS: chunks, chunkSeconds: Self.chunkSeconds)
        #expect(trimmed <= LeadingSilence.maximumTrimSeconds)
    }

    @Test("an empty series has nothing to trim")
    func emptySeriesTrimsNothing() {
        #expect(LeadingSilence.secondsToTrim(chunkRMS: [], chunkSeconds: Self.chunkSeconds) == 0)
    }

    @Test("a zero chunk duration cannot produce a trim, since the seconds are unknowable")
    func zeroChunkDurationTrimsNothing() {
        let chunks = Array(repeating: 0.0, count: 22) + Array(repeating: 0.05, count: 60)
        #expect(LeadingSilence.secondsToTrim(chunkRMS: chunks, chunkSeconds: 0) == 0)
    }
}
