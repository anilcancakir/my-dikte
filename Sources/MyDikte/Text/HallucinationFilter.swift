import Foundation

/// Catches Whisper-class stock phrases invented for near-silent clips.
///
/// Fed near-silence, a transcription model does not return an empty string; it invents one.
/// This is the second line of defence behind voice-activity detection: a stock phrase returned
/// for a short clip is almost certainly hallucinated, not spoken.
enum HallucinationFilter {
    /// Stock phrases models produce when handed silence. Kept deliberately narrow: only
    /// sentences nobody dictates on purpose in a two-second clip. Ported verbatim from
    /// `references/dikte/dikte/vad.py:20-29`; do not widen this set with guesses.
    static let phrases: Set<String> = [
        "altyazi mk", "altyazi m k", "altyazi", "altyazilar",
        "abone olmayi unutmayin", "izlediginiz icin tesekkurler",
        "izlediginiz icin tesekkur ederim", "izlediginiz icin tesekkur ederiz",
        "kanalima abone olmayi unutmayin", "altyazi mk altyazi mk",
        "thanks for watching", "thank you for watching", "thanks for watching!",
        "please subscribe", "subscribe to my channel", "you", "bye",
        "mbc masr", "sous titres realises par la communaute damara org",
        "amara org community", "sous titrage st 501",
    ]

    /// True when `text` is almost certainly an invented stock phrase rather than real speech.
    ///
    /// Stock phrases only appear in short clips: a model handed several seconds of real audio
    /// does not fall back to them, so a long recording skips the check entirely.
    static func looksLikeHallucination(
        text: String,
        duration: TimeInterval,
        maxDuration: TimeInterval = 6.0
    ) -> Bool {
        guard duration <= maxDuration else {
            return false
        }

        let normalised: String = TurkishFolding.normalise(text)
        if normalised.isEmpty {
            return true
        }
        if phrases.contains(normalised) {
            return true
        }

        // "Altyazı M.K. Altyazı M.K. Altyazı M.K.": the same stock line repeated.
        let words: [String] = normalised.split(separator: " ").map(String.init)
        guard !words.isEmpty else {
            return false
        }
        for phrase in phrases {
            let parts: [String] = phrase.split(separator: " ").map(String.init)
            guard parts.count >= 2, words.count % parts.count == 0 else {
                continue
            }
            let repeated: [String] = Array(repeating: parts, count: words.count / parts.count).flatMap { $0 }
            if words == repeated {
                return true
            }
        }
        return false
    }
}
