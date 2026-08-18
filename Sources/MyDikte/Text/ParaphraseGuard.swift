import Foundation

/// Guards against a cleanup model paraphrasing the user's own words instead of
/// merely cleaning them: fixing punctuation and dropping fillers is welcome,
/// rewording or translating is not. This is the last automated check before a
/// cleaned transcript is inserted, so on any doubt it rejects and the pipeline
/// falls back to the raw transcript.
public enum ParaphraseGuard {
    /// The outcome of comparing a raw transcript against its cleaned counterpart.
    public enum Result: Equatable {
        case accept
        case reject(reason: String)
    }

    /// Compares `raw` and `cleaned` and decides whether `cleaned` is safe to insert.
    ///
    /// - Parameters:
    ///   - raw: the unmodified transcript from the speech-to-text provider.
    ///   - cleaned: the cleanup model's output for the same utterance.
    ///   - glossary: technical identifiers the user configured. Compared with
    ///     `localizedCaseInsensitiveContains` on the plain strings, so a suffixed
    ///     form such as "Redis'in" already satisfies a "Redis" entry; no Turkish
    ///     normalisation is applied, since glossary entries are identifiers that
    ///     appear the same way in both strings.
    ///   - wordCountTolerance: the fraction of `raw`'s word count that `cleaned`
    ///     may drift by in either direction before it is treated as a rewrite
    ///     rather than a cleanup.
    /// - Returns: `.accept` when `cleaned` looks like a faithful cleanup of `raw`,
    ///   `.reject(reason:)` with a user-facing reason otherwise.
    public static func check(
        raw: String,
        cleaned: String,
        glossary: [String],
        wordCountTolerance: Double = 1.0 / 3.0
    ) -> Result {
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Cleanup never produces nothing from something.
        if trimmedCleaned.isEmpty && !trimmedRaw.isEmpty {
            return .reject(reason: "Cleanup produced an empty result.")
        }

        // 2. A dropped glossary term is the strongest paraphrase signal, since
        //    these are technical identifiers the user expects verbatim.
        for term in glossary where raw.localizedCaseInsensitiveContains(term) {
            if !cleaned.localizedCaseInsensitiveContains(term) {
                return .reject(reason: "Glossary term \"\(term)\" was dropped during cleanup.")
            }
        }

        // 3. Cleanup removes fillers and adds punctuation; it does not restructure the utterance,
        //    so a large word-count swing signals a rewrite. The two directions are not
        //    symmetric, and treating them as one number is what made this check misfire: growth
        //    means the model invented text, while shrinkage is the model doing its job. A short
        //    Turkish dictation is routinely a third fillers ("ıı bugün şey servisleri
        //    güncelledim yani" is six words, three of them filler), so a flat tolerance rejects
        //    ordinary cleanups. Word counts alone cannot tell "dropped three fillers" from
        //    "dropped three content words": both are six to three. So shrinkage is judged by
        //    WHAT was removed, and only an unexplained removal falls back to the tolerance.
        let rawWordCount = wordCount(of: trimmedRaw)
        let cleanedWordCount = wordCount(of: trimmedCleaned)
        if rawWordCount > 0 {
            let upperBound = Double(rawWordCount) * (1 + wordCountTolerance)
            if Double(cleanedWordCount) > upperBound {
                return .reject(
                    reason: "Cleanup grew the text from \(rawWordCount) words to \(cleanedWordCount)."
                )
            }

            let lowerBound = Double(rawWordCount) * (1 - wordCountTolerance)
            if Double(cleanedWordCount) < lowerBound, !removalsAreAllFillers(raw: trimmedRaw, cleaned: trimmedCleaned) {
                return .reject(
                    reason: "Cleanup dropped content, not just fillers: "
                        + "\(rawWordCount) words became \(cleanedWordCount)."
                )
            }
        }

        // 4. Cleanup removes words and adds punctuation; it does not invent words. This is the
        //    check that catches a same-length, same-position substitution, which checks 2 and 3
        //    cannot see by construction: the measured failure was Turkish "yine" becoming English
        //    "again" with the word count and every glossary term intact.
        if let introduced = introducedWord(raw: trimmedRaw, cleaned: trimmedCleaned, glossary: glossary) {
            return .reject(reason: "Cleanup introduced a word that was not spoken: \"\(introduced)\".")
        }

        return .accept
    }

    /// The first word in `cleaned` that cannot be accounted for by anything in `raw` or the
    /// glossary, or `nil` when every word is accounted for.
    ///
    /// A cleaned word is accounted for when it shares a stem with some raw word in either
    /// direction, which is what keeps the legitimate cases allowed: a Turkish suffix added
    /// ("Redis" to "Redis'in"), a run-on split ("arayüzü" to "ara yüzü"), and a misheard word
    /// merged back together ("kuber netis" to "Kubernetes") all contain or are contained by a raw
    /// word. A glossary term is allowed outright, because the cleanup prompt is explicitly asked
    /// to repair misheard technical terms into their configured spelling.
    private static func introducedWord(raw: String, cleaned: String, glossary: [String]) -> String? {
        let rawStems: [String] = stems(of: raw)
        let glossaryStems: [String] = glossary.flatMap { stems(of: $0) }

        for word in stems(of: cleaned) {
            // Too short to carry a paraphrase, and short strings match everything by accident.
            if word.count < minimumComparableLength {
                continue
            }
            if glossaryStems.contains(where: { $0.contains(word) || word.contains($0) }) {
                continue
            }
            if rawStems.contains(where: { $0.contains(word) || word.contains($0) }) {
                continue
            }
            return word
        }
        return nil
    }

    /// Whether every word `cleaned` dropped is one the cleanup prompt is explicitly told to drop.
    ///
    /// The prompt's own filler list is the source here, so this check and the instruction the
    /// model receives cannot drift apart. The list is deliberately not exhaustive, which is safe:
    /// an unlisted filler simply falls back to the word-count tolerance rather than being treated
    /// as content loss.
    private static func removalsAreAllFillers(raw: String, cleaned: String) -> Bool {
        var remaining: [String: Int] = [:]
        for word in stems(of: cleaned) {
            remaining[word, default: 0] += 1
        }

        for word in stems(of: raw) {
            if let count = remaining[word], count > 0 {
                remaining[word] = count - 1
                continue
            }
            // This raw word is gone from the cleaned text. It has to be a filler, a thinking
            // sound, or a word that survives inside a longer cleaned word (a merge).
            if fillers.contains(word) {
                continue
            }
            if stems(of: cleaned).contains(where: { $0.contains(word) }) {
                continue
            }
            return false
        }
        return true
    }

    /// The filler words and thinking sounds `CLEANUP_PROMPT_TR` names, lowercased.
    private static let fillers: Set<String> = [
        "ıı", "ii", "ee", "ııı", "iii", "mmm", "mm", "hmm", "aa", "eee",
        "hani", "yani", "işte", "şey", "falan", "böyle", "aslında", "ya",
    ]

    /// Lowercased, punctuation-free words. Deliberately local rather than reusing the Turkish
    /// folding used for hallucination matching: this comparison is between two renderings of the
    /// same utterance, so it needs casing and punctuation gone and nothing more.
    private static func stems(of text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Words shorter than this are exempt from the introduced-word check: they carry too little
    /// meaning to be a paraphrase and they collide with longer words by chance.
    private static let minimumComparableLength: Int = 3

    private static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
