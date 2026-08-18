import Foundation
import Testing

@testable import MyDikte

/// Frequency counting over the dictation log, and the four things that make the count usable: it
/// ranks by count, it groups two spellings of one Turkish word together, it never suggests a term
/// the glossary already covers, and it survives a half-written last line.
///
/// Every test that touches a file uses a scratch directory, never `DictationLog.defaultDirectory`,
/// so no test run reads or writes the user's own `log.jsonl`.
@Suite("GuardConcernLedger")
struct GuardConcernLedgerTests {
    @Test("a term flagged more often ranks higher")
    func rankingFollowsTheCount() {
        let records: [DictationRecord] = [
            Self.record(term: "optimize", at: 100),
            Self.record(term: "speech", at: 200),
            Self.record(term: "optimize", at: 300),
            Self.record(term: "optimize", at: 400),
        ]

        let candidates = GuardConcernLedger.candidates(in: records, glossaryTerms: [])

        #expect(candidates.map(\.term) == ["optimize", "speech"])
        #expect(candidates.first?.count == 3)
        #expect(candidates.last?.count == 1)
    }

    @Test("each candidate carries the last time it was flagged")
    func candidatesCarryTheirLastSeenDate() {
        let records: [DictationRecord] = [
            Self.record(term: "optimize", at: 100),
            Self.record(term: "optimize", at: 900),
        ]

        let candidates = GuardConcernLedger.candidates(in: records, glossaryTerms: [])

        #expect(candidates.first?.lastSeen == Date(timeIntervalSince1970: 900))
    }

    /// An equal count is the common case on a young log, where nearly every term has been flagged
    /// once, so the tie-break decides the whole order the user reads.
    @Test("terms with an equal count are ordered by the most recent one first")
    func tiesBreakOnRecency() {
        let records: [DictationRecord] = [
            Self.record(term: "speech", at: 100),
            Self.record(term: "optimize", at: 200),
        ]

        let candidates = GuardConcernLedger.candidates(in: records, glossaryTerms: [])

        #expect(candidates.map(\.term) == ["optimize", "speech"])
    }

    /// Two spellings of one Turkish word are one term. Folding is what makes that true, and it is the
    /// same folding the guard compares with, so the ledger cannot disagree with the check that fed it.
    @Test("two spellings of one word are counted as one term")
    func foldedSpellingsCountAsOneTerm() {
        let records: [DictationRecord] = [
            Self.record(term: "işte", at: 100),
            Self.record(term: "iste", at: 200),
        ]

        let candidates = GuardConcernLedger.candidates(in: records, glossaryTerms: [])

        #expect(candidates.count == 1)
        #expect(candidates.first?.count == 2)
    }

    @Test("a grouped term is shown with its most recent spelling")
    func groupedTermUsesItsMostRecentSpelling() {
        let records: [DictationRecord] = [
            Self.record(term: "iste", at: 100),
            Self.record(term: "işte", at: 200),
        ]

        #expect(GuardConcernLedger.candidates(in: records, glossaryTerms: []).first?.term == "işte")
    }

    @Test("a term already in the glossary is not suggested again")
    func glossaryTermsAreExcluded() {
        let records: [DictationRecord] = [
            Self.record(term: "optimize", at: 100),
            Self.record(term: "PyQt", at: 200),
        ]

        let candidates = GuardConcernLedger.candidates(in: records, glossaryTerms: ["PyQt"])

        #expect(candidates.map(\.term) == ["optimize"])
    }

    @Test("the glossary comparison is folded, so a diacritic is not a different term")
    func glossaryExclusionIsFolded() {
        let records = [Self.record(term: "işte", at: 100)]

        #expect(GuardConcernLedger.candidates(in: records, glossaryTerms: ["iste"]).isEmpty)
    }

    /// The measured reason: a multi-word glossary entry already licenses each of its words inside the
    /// guard, so suggesting one of them would ask the user to lengthen the glossary for nothing, and a
    /// longer glossary measured worse (six focused terms returned "LLM-friendly" correctly on three of
    /// three runs, nineteen returned "erlenme front" on three of three).
    @Test("a word already covered by a multi-word glossary entry is not suggested")
    func wordsInsideAGlossaryEntryAreExcluded() {
        let records = [Self.record(term: "speech", at: 100)]

        #expect(GuardConcernLedger.candidates(in: records, glossaryTerms: ["Speech to Text"]).isEmpty)
    }

    @Test("a dictation with no concern contributes nothing")
    func recordsWithoutConcernsAreIgnored() {
        let records: [DictationRecord] = [
            Self.record(term: nil, at: 100),
            Self.record(term: "optimize", at: 200),
        ]

        let candidates = GuardConcernLedger.candidates(in: records, glossaryTerms: [])

        #expect(candidates.count == 1)
        #expect(candidates.first?.count == 1)
    }

    /// Two of the five concern kinds are about the whole utterance rather than one word, so they have
    /// no term to count and must not become an empty candidate.
    @Test("a concern with no term contributes nothing")
    func concernsWithoutATermAreIgnored() {
        let records = [
            Self.record(
                concern: ParaphraseGuard.Concern(
                    kind: .droppedContent,
                    wordCounts: ParaphraseGuard.Concern.WordCounts(raw: 22, cleaned: 14)
                ),
                at: 100
            ),
        ]

        #expect(GuardConcernLedger.candidates(in: records, glossaryTerms: []).isEmpty)
    }

    @Test("a log read from disk produces the same candidates")
    func readingFromDiskProducesCandidates() throws {
        let directory = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try DictationLog.append(Self.record(term: "optimize", at: 100), to: directory)
        try DictationLog.append(Self.record(term: "optimize", at: 200), to: directory)
        try DictationLog.append(Self.record(term: "PyQt", at: 300), to: directory)

        let candidates = GuardConcernLedger.candidates(glossaryTerms: ["PyQt"], in: directory)

        #expect(candidates.map(\.term) == ["optimize"])
        #expect(candidates.first?.count == 2)
    }

    /// The log is appended to line by line, so the process can die mid-write and leave a partial last
    /// line. One bad line must cost one dictation, not the whole read.
    @Test("a half-written last line costs one record, not the whole file")
    func malformedLastLineIsSkipped() throws {
        let directory = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try DictationLog.append(Self.record(term: "optimize", at: 100), to: directory)
        let handle = try FileHandle(forWritingTo: DictationLog.fileURL(in: directory))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"timestamp\":\"2026-08-18T17:0".utf8))
        try handle.close()

        let candidates = GuardConcernLedger.candidates(glossaryTerms: [], in: directory)

        #expect(candidates.map(\.term) == ["optimize"])
    }

    @Test("a log that does not exist yet has no candidates rather than an error")
    func missingLogHasNoCandidates() {
        let directory = Self.makeScratchDirectory()

        #expect(GuardConcernLedger.candidates(glossaryTerms: [], in: directory).isEmpty)
    }

    private static func makeScratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MyDikteGuardConcernLedgerTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func record(term: String?, at seconds: TimeInterval) -> DictationRecord {
        record(
            concern: term.map { ParaphraseGuard.Concern(kind: .introducedWord, term: $0) },
            at: seconds
        )
    }

    private static func record(concern: ParaphraseGuard.Concern?, at seconds: TimeInterval) -> DictationRecord {
        DictationRecord(
            timestamp: Date(timeIntervalSince1970: seconds),
            mode: .dictate,
            audioPath: nil,
            duration: 4.0,
            rawTranscript: "ham metin",
            finalText: "Ham metin.",
            paraphraseRejectionReason: concern.map { "Advisory: \($0.sentence)" },
            rejectedCleanup: nil,
            guardConcern: concern,
            transcriptionModelId: "whisper-large-v3",
            cleanupModelId: "openai/gpt-oss-120b",
            timings: DictationRecord.Timings(
                captureMs: 120,
                encodeMs: 40,
                transcribeMs: 300,
                cleanupMs: 150,
                insertMs: 10,
                totalMs: 620
            )
        )
    }
}
