import Foundation

/// Decodes a Groq `verbose_json` transcription response.
///
/// Every field beyond `text` is optional and unknown top-level fields are silently ignored by
/// `Decodable`. This is deliberate, not an oversight: Step 2's own probe evidence, gathered in
/// this same wave, decides which of `segments`, `no_speech_prob`, `avg_logprob` and
/// `compression_ratio` actually arrive, so this type must decode successfully either way. See
/// `.ac/plans/my-dikte-swift-macos/research/librarian-stt-contracts.md` for the documented field
/// set this mirrors.
struct TranscriptionResponse: Decodable {
    let text: String
    let segments: [Segment]?
    /// ElevenLabs Scribe's per-word array. Whisper reports its confidence per segment; Scribe
    /// reports no segments at all and a `logprob` on every word instead, so the two providers
    /// cannot share one field and both are decoded optionally.
    let words: [Word]?

    /// Written out rather than left to the memberwise initialiser so that adding `words` did not
    /// force every existing call site to pass it. `Decodable`'s own initialiser is still
    /// synthesised; only the memberwise one is replaced.
    init(text: String, segments: [Segment]?, words: [Word]? = nil) {
        self.text = text
        self.segments = segments
        self.words = words
    }

    /// One quality-signal segment. All fields optional for the same reason as the parent type.
    struct Segment: Decodable {
        let noSpeechProb: Double?
        let avgLogprob: Double?
        let compressionRatio: Double?

        enum CodingKeys: String, CodingKey {
            case noSpeechProb = "no_speech_prob"
            case avgLogprob = "avg_logprob"
            case compressionRatio = "compression_ratio"
        }
    }

    /// One word from a Scribe response. `type` distinguishes a spoken word from the spacing and
    /// audio-event entries that share the array, and only spoken words carry a usable `logprob`.
    struct Word: Decodable {
        let text: String?
        let type: String?
        let logprob: Double?

        static let spokenType = "word"
    }
}

extension TranscriptionResponse {
    /// The geometric mean of the per-word token probabilities, or nil when the provider reported
    /// none. Scribe returns a natural-log probability per word, so the mean is taken in log space
    /// and exponentiated back, following
    /// `livekit-plugins-elevenlabs/stt.py`'s `_speech_confidence`.
    ///
    /// **Reported, never enforced.** Four real recordings measured 0.823 to 0.972, and the 0.823 run
    /// was the worst transcript of the set, so the signal is real. It is still only four points, and
    /// this project has already paid once for a threshold set from reasoning rather than data: the
    /// paraphrase guard rejected three correct cleanups in a day and caught nothing. So this value
    /// goes to the log and waits for enough runs to place a threshold honestly.
    var wordConfidence: Double? {
        guard let words else {
            return nil
        }
        let logprobs: [Double] = words
            .filter { $0.type == Word.spokenType }
            .compactMap(\.logprob)
        guard !logprobs.isEmpty else {
            return nil
        }
        let mean: Double = logprobs.reduce(0, +) / Double(logprobs.count)
        return min(1.0, max(0.0, exp(mean)))
    }
}
