import Foundation
import Security

/// Builds the request messages sent to the cleanup model, for either mode.
///
/// The system message carries the mode's prompt plus an optional glossary block; the user
/// message carries the transcript, fenced. The fence is the boundary that keeps a dictated
/// sentence from reading as an instruction to the model, the same reason
/// `references/VoiceInk/.../AIEnhancementService.swift:229-231` fences its own transcript.
enum PromptAssembly {
    /// Which system prompt a request is assembled for.
    enum Mode {
        /// Clean a raw Turkish transcript into readable text, same language, same register.
        case cleanup
        /// Rewrite the transcript into an English prompt addressed to Claude Opus 5.
        case promptRewrite
    }

    /// The two messages a chat-completions request needs.
    struct Messages {
        let system: String
        let user: String
    }

    /// The framing `GLOSSARY_RULE_TR` uses in `references/dikte/dikte/config.py:190-192`: a
    /// heading, the term list, and the rule that a similar-sounding word is probably one of
    /// these. Kept in Turkish regardless of mode because it describes the Turkish transcript
    /// both modes read, not the language of their own system prompt.
    private static let glossaryHeading = "KONUŞMACININ KULLANDIĞI İSİM VE TERİMLER"
    private static let glossaryRule =
        "Transkriptteki bir kelime bunlardan birine sesçe benziyorsa büyük ihtimalle o kelimedir; "
        + "yukarıdaki yazımı kullan."

    /// Assembles the system and user message for `mode`, given the raw or cleaned transcript
    /// and the glossary terms the user configured.
    static func messages(for mode: Mode, transcript: String, glossary: [String] = []) -> Messages {
        let prompt: String
        switch mode {
        case .cleanup:
            prompt = CleanupPrompt.systemMessage
        case .promptRewrite:
            prompt = PromptRewritePrompt.systemMessage
        }
        return Messages(
            system: prompt + glossaryBlock(for: glossary),
            user: fence(transcript)
        )
    }

    /// Empty when there is nothing to say; otherwise the heading, the terms, and the rule.
    private static func glossaryBlock(for terms: [String]) -> String {
        guard !terms.isEmpty else {
            return ""
        }
        let list = terms.map { "- \($0)" }.joined(separator: "\n")
        return "\n\n\(glossaryHeading)\n\(list)\n\(glossaryRule)"
    }

    /// Wraps `transcript` in a nonce-tagged `<TRANSCRIPT>` fence.
    ///
    /// A transcript is dictated speech, not trusted markup, so it must not be able to close the
    /// fence early by containing the literal closing tag. The fence carries a per-request random
    /// id instead of escaping the text, because **the transcript is never modified**: this app
    /// inserts what the user actually said, and a developer dictating Turkish says things like
    /// "Vector<String>" or "x < 5". Rewriting those angle brackets to full-width look-alikes
    /// would corrupt the dictation in exactly the way the paraphrase guard exists to prevent,
    /// and the corruption would reach the caret.
    private static func fence(_ transcript: String) -> String {
        let nonce: String = Self.nonce()
        return "\n<TRANSCRIPT id=\"\(nonce)\">\n\(transcript)\n</TRANSCRIPT id=\"\(nonce)\">"
    }

    /// 16 hex characters from the system CSPRNG, so a dictation cannot guess the closing tag.
    private static func nonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        // Falls back to a random draw only if the CSPRNG is unavailable, which on macOS it is
        // not; either way the value only has to be unguessable to a speaker, not to an attacker
        // with local code execution.
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<8).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
