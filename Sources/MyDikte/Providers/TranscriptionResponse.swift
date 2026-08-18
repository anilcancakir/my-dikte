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
}
