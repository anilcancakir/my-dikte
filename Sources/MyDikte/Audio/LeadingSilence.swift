import Foundation

/// Decides how much dead air to drop from the front of a recording before it is encoded and sent.
///
/// This exists because of one measured failure. A real 8.14 s dictation with AirPods as the input
/// device came back from Groq as `"İzlediğiniz için teşekkürler."`, a stock Whisper caption phrase,
/// which then passed the hallucination filter and reached the caret. The audio was not the problem:
/// peak -3.0 dBFS, zero-crossing rate 0.103, lag-1 autocorrelation 0.987, all unambiguously speech.
/// The **head** of it was. A Bluetooth microphone link opens roughly a second and a half after
/// `engine.start()`, and until it does the tap delivers exact zeros, which were spooled and sent.
/// Trimming that 1.85 s and re-sending the identical samples returned the real sentence,
/// `"Bundan beri baktığım işlerin hiçbirinde bir değişiklik olmadığı için ben deploy yapmayı denedim."`
///
/// So Whisper does not merely ignore leading silence, it invents text to fill it. The built-in
/// microphone never showed this because its cold start is 156 ms and what it delivers meanwhile is a
/// noise floor rather than zeros.
///
/// The decision is deliberately conservative in three ways, because trimming too much would cut the
/// start of a word and that is worse than sending some silence: only **digital** silence counts, not a
/// quiet room; a short lead-in is left alone; and a pre-roll is always kept before the first audible
/// chunk.
enum LeadingSilence {
    /// Below this RMS a chunk is treated as digital silence rather than quiet audio.
    ///
    /// About -66 dBFS. A Bluetooth link that has not opened yet reports exactly 0.0, and the measured
    /// room tone on this machine sits near 0.0008 (-62 dBFS), so the threshold sits between the two
    /// and closer to zero. Anything a microphone actually produces stays.
    static let silenceRMS: Double = 0.0005

    /// Shorter lead-ins than this are left alone. The built-in microphone's measured cold start is
    /// 156 ms, and trimming that buys nothing while risking a soft onset.
    static let minimumTrimSeconds: Double = 0.4

    /// Never drop more than this, whatever the series says. A cap keeps a pathological reading from
    /// swallowing a recording, and no observed link takes longer than this to open.
    static let maximumTrimSeconds: Double = 3.0

    /// Audio kept before the first audible chunk, so a quiet word beginning inside that chunk is not
    /// clipped by trimming up to its edge.
    static let preRollSeconds: Double = 0.15

    /// How many seconds to drop from the front of a recording, or `0` when nothing should be dropped.
    ///
    /// - Parameters:
    ///   - chunkRMS: one RMS value per converted buffer, in capture order, as
    ///     `AudioCapture.Recording` reports it.
    ///   - chunkSeconds: the mean duration each of those values covers.
    static func secondsToTrim(chunkRMS: [Double], chunkSeconds: Double) -> Double {
        guard chunkSeconds > 0, !chunkRMS.isEmpty else {
            return 0
        }

        guard let firstAudible: Int = chunkRMS.firstIndex(where: { $0 > silenceRMS }) else {
            // Silent throughout. Trimming would leave the VAD nothing to measure and the log nothing
            // to report, and the correct outcome for this recording is a room-tone rejection, not a
            // shortened file.
            return 0
        }

        let silentSeconds = Double(firstAudible) * chunkSeconds
        guard silentSeconds >= minimumTrimSeconds else {
            return 0
        }

        return min(maximumTrimSeconds, silentSeconds - preRollSeconds)
    }
}
