import Foundation
import Testing

@testable import MyDikte

/// Covers `HistoryEntryList`'s pure logic: newest-first ordering, the raw transcript riding along
/// with each entry, and deleting exactly one JSONL line while leaving the rest parseable.
///
/// Every test uses a scratch directory under `FileManager.default.temporaryDirectory`, never
/// `DictationLog.defaultDirectory`, matching `DictationLogTests`'s own reason: no test run may
/// ever touch the user's own `log.jsonl`.
@Suite("HistoryEntryList reading and deleting the log")
struct HistoryEntryListTests {
    @Test("load returns records newest first")
    func loadReturnsRecordsNewestFirst() throws {
        let directory = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldest = Self.makeRecord(rawTranscript: "en eski", finalText: "En eski.")
        let middle = Self.makeRecord(rawTranscript: "orta", finalText: "Orta.")
        let newest = Self.makeRecord(rawTranscript: "en yeni", finalText: "En yeni.")
        try DictationLog.append(oldest, to: directory)
        try DictationLog.append(middle, to: directory)
        try DictationLog.append(newest, to: directory)

        let entries = HistoryEntryList.load(from: directory)

        #expect(entries.map(\.record) == [newest, middle, oldest])
    }

    @Test("each loaded entry exposes its own raw transcript")
    func loadedEntryExposesRawTranscript() throws {
        let directory = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let record = Self.makeRecord(rawTranscript: "ham hali", finalText: "Cleaned up version.")
        try DictationLog.append(record, to: directory)

        let entries = HistoryEntryList.load(from: directory)

        #expect(entries.count == 1)
        #expect(entries[0].record.rawTranscript == "ham hali")
        #expect(entries[0].record.finalText == "Cleaned up version.")
    }

    @Test("deleting the middle record removes exactly that line and leaves the rest parseable")
    func deletingMiddleRecordLeavesRestParseable() throws {
        let directory = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldest = Self.makeRecord(rawTranscript: "birinci", finalText: "Birinci.")
        let middle = Self.makeRecord(rawTranscript: "ikinci", finalText: "İkinci.")
        let newest = Self.makeRecord(rawTranscript: "ucuncu", finalText: "Üçüncü.")
        try DictationLog.append(oldest, to: directory)
        try DictationLog.append(middle, to: directory)
        try DictationLog.append(newest, to: directory)

        // `middle` is at file index 1 (oldest first on disk).
        try HistoryEntryList.delete(fileIndex: 1, from: directory)

        let remaining = DictationLog.readAll(from: directory)
        #expect(remaining == [oldest, newest])
    }

    @Test("deleting an out-of-range index throws entryNotFound")
    func deletingOutOfRangeIndexThrows() throws {
        let directory = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try DictationLog.append(Self.makeRecord(), to: directory)

        #expect(throws: HistoryError.self) {
            try HistoryEntryList.delete(fileIndex: 5, from: directory)
        }
    }

    /// A directory of this test's own, so nothing here touches the user's real `log.jsonl` and no
    /// two tests in this suite can race each other under Swift Testing's default parallel
    /// execution.
    private static func makeScratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MyDikteHistoryEntryListTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func makeRecord(
        rawTranscript: String = "ham metin",
        finalText: String = "Ham metin."
    ) -> DictationRecord {
        DictationRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            mode: .dictate,
            audioPath: nil,
            duration: 3.4,
            rawTranscript: rawTranscript,
            finalText: finalText,
            paraphraseRejectionReason: nil,
            transcriptionModelId: "whisper-large-v3",
            cleanupModelId: "gpt-oss-120b",
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
