import Foundation

/// Counts how often the paraphrase guard has flagged each term, reading `log.jsonl` and nothing else.
///
/// This is frequency counting, in the plainest sense of the words, and it is deliberately not more:
/// no model, no score, no weighting, no decay curve. It answers one question, "which terms has the
/// guard flagged, how often, and when was each last seen", and ranks the answer by count. Nothing
/// here learns in the machine-learning sense, and a later change that adds a heuristic should be a
/// change with a measurement behind it rather than an extension of this type.
///
/// It reads the structured `DictationRecord.guardConcern` field, never the human-readable reason. A
/// count taken by matching prose would break silently the first time a sentence was reworded, which
/// is the entire reason the concern is stored as data.
///
/// It suggests and never adds. A longer glossary measured measurably worse on this machine: on one
/// recording, six focused terms returned "LLM-friendly" correctly on three of three runs while
/// nineteen terms returned "erlenme front" on three of three, because Whisper reads that field as
/// text preceding the audio and unrelated terms crowd out the relevant ones. So the ranking is a
/// shortlist for the user to choose from, and growing the glossary without them choosing would be a
/// regression rather than a convenience.
enum GuardConcernLedger {
    /// One term the guard keeps flagging, with the two numbers that justify suggesting it.
    struct Candidate: Equatable, Sendable, Identifiable {
        /// The term as the most recent record spells it, so a suggestion can be added to the glossary
        /// exactly as it stands.
        let term: String
        let count: Int
        let lastSeen: Date

        /// The folded form, which is also what groups two spellings of one word into one candidate.
        var id: String {
            TurkishFolding.normalise(term)
        }
    }

    /// Ranked candidates from the log in `directory`.
    ///
    /// Reads through `DictationLog.readAll`, which skips a line it cannot decode: the log is appended
    /// to line by line, so a process that died mid-write leaves a partial last line, and that must
    /// cost one dictation rather than the whole history.
    static func candidates(
        glossaryTerms: [String],
        in directory: URL = DictationLog.defaultDirectory
    ) -> [Candidate] {
        candidates(in: DictationLog.readAll(from: directory), glossaryTerms: glossaryTerms)
    }

    /// The counting itself, over records already in memory.
    ///
    /// Ranked by count, then by recency, then alphabetically. The two tie-breaks are not decoration: on
    /// a young log almost every term has been flagged exactly once, so without them the order the user
    /// reads would be whatever order the file happened to be in.
    static func candidates(in records: [DictationRecord], glossaryTerms: [String]) -> [Candidate] {
        let excluded: Set<String> = coveredTerms(inGlossary: glossaryTerms)
        var counted: [String: Candidate] = [:]

        for record in records {
            guard let term = record.guardConcern?.term else {
                continue
            }
            let folded: String = TurkishFolding.normalise(term)
            guard !folded.isEmpty, !excluded.contains(folded) else {
                continue
            }

            guard let existing = counted[folded] else {
                counted[folded] = Candidate(term: term, count: 1, lastSeen: record.timestamp)
                continue
            }
            // The newest spelling wins, because it is the one the current models produce.
            let isNewer: Bool = record.timestamp > existing.lastSeen
            counted[folded] = Candidate(
                term: isNewer ? term : existing.term,
                count: existing.count + 1,
                lastSeen: max(existing.lastSeen, record.timestamp)
            )
        }

        return counted.values.sorted { left, right in
            if left.count != right.count {
                return left.count > right.count
            }
            if left.lastSeen != right.lastSeen {
                return left.lastSeen > right.lastSeen
            }
            return left.id < right.id
        }
    }

    /// Every folded word the glossary already covers: each entry whole, and each word inside a
    /// multi-word entry.
    ///
    /// The words matter as much as the entries, because `ParaphraseGuard` licenses a cleaned word when
    /// any glossary entry contains it, so "Speech to Text" in the glossary already covers "speech".
    /// Suggesting it anyway would ask the user to lengthen the glossary for no accuracy at all, and
    /// length is the one thing measured to make the glossary worse.
    private static func coveredTerms(inGlossary glossaryTerms: [String]) -> Set<String> {
        var covered: Set<String> = []
        for term in glossaryTerms {
            let folded: String = TurkishFolding.normalise(term)
            guard !folded.isEmpty else {
                continue
            }
            covered.insert(folded)
            for word in folded.split(separator: " ") {
                covered.insert(String(word))
            }
        }
        return covered
    }
}
