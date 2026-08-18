import Foundation

/// Errors surfaced by `TranscriptionClient`. Step 13's chat client defines its own error enum, so
/// this type belongs to transcription alone.
enum ProviderError: Error, LocalizedError, Equatable {
    /// No key found in the Keychain for `account`. Named rather than generic, so the message can
    /// point the user at the exact settings field rather than a blank "authentication failed".
    case missingAPIKey(account: String)

    /// A non-2xx HTTP response, with the provider's own message extracted when the body carried
    /// one, or the localised status string when it did not: a bad `User-Agent` reached Groq's
    /// edge as an HTTP 403 with no body at all (`evidence/step-02-groq-seam.txt`, section A4), so
    /// this case must be constructible without a parsed envelope.
    case requestFailed(status: Int, message: String)

    /// The response was not decodable as `TranscriptionResponse` at all, distinct from a
    /// well-formed response that fails the quality gate.
    case invalidResponse

    /// The decoded response's per-segment quality fields (Groq only) crossed the reject
    /// threshold: a high aggregate `no_speech_prob` or a sharply negative aggregate
    /// `avg_logprob`.
    /// - Parameter transcript: what the model actually returned. Carried so the rejected text
    ///   reaches the log: a threshold that discards its own evidence cannot be tuned, and this one
    ///   fired on a real dictation that then left no trace anywhere.
    case lowQualityTranscript(reason: String, transcript: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let account):
            return "No API key found for \"\(account)\". Enter one in Settings, under Models."
        case .requestFailed(let status, let message):
            return "Transcription request failed (HTTP \(status)): \(message)"
        case .invalidResponse:
            return "The transcription provider returned a response that could not be understood."
        case .lowQualityTranscript(let reason, _):
            return "The transcription looked unreliable and was rejected: \(reason)"
        }
    }
}
