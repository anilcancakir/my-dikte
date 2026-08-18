import Foundation
import Testing

@testable import MyDikte

/// Covers `DictationLog`'s append-only JSONL persistence and the schema itself: a record must
/// round-trip through `JSONDecoder` unchanged, appending must never rewrite earlier lines, and a
/// `nil` audio path (retention disabled) must decode cleanly rather than requiring a placeholder.
///
/// Every test uses a scratch directory under `FileManager.default.temporaryDirectory`, never
/// `DictationLog.defaultDirectory`, so no test run ever touches the user's own `log.jsonl`, per the
/// lesson `SettingsTests` already paid for under Swift Testing's parallel execution.
@Suite("DictationLog append-only JSONL")
struct DictationLogTests {
    @Test("a written line round-trips through JSONDecoder with every field preserved")
    func recordRoundTripsThroughJSONDecoder() throws {
        let directory = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let record = Self.makeRecord(rawTranscript: "merhaba dünya", finalText: "Merhaba dünya.")
        try DictationLog.append(record, to: directory)

        let decoded = try Self.decodeLines(from: directory)
        #expect(decoded == [record])
    }

    @Test("appending twice yields two parseable lines, oldest first")
    func appendingTwiceYieldsTwoParseableLines() throws {
        let directory = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = Self.makeRecord(rawTranscript: "birinci", finalText: "Birinci.")
        let second = Self.makeRecord(rawTranscript: "ikinci", finalText: "İkinci.")
        try DictationLog.append(first, to: directory)
        try DictationLog.append(second, to: directory)

        let decoded = try Self.decodeLines(from: directory)
        #expect(decoded == [first, second])
    }

    @Test("a record with a null audio path decodes")
    func recordWithNullAudioPathDecodes() throws {
        let directory = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let record = Self.makeRecord(rawTranscript: "ses tutulmadı", finalText: "Ses tutulmadı.", audioPath: nil)
        try DictationLog.append(record, to: directory)

        let decoded = try Self.decodeLines(from: directory)
        #expect(decoded.count == 1)
        #expect(decoded[0].audioPath == nil)
    }

    /// The reason string quotes word counts and cannot say whether the guard was right, so the
    /// candidate it turned down has to survive the round trip: without it, tuning the guard against
    /// real dictations is impossible, which is exactly how a wrong diagnosis survived a whole wave.
    @Test("a rejected cleanup candidate survives the round trip alongside its reason")
    func rejectedCleanupCandidateRoundTrips() throws {
        let directory = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try DictationLog.append(
            Self.makeRecord(
                rawTranscript: "ham metin",
                finalText: "ham metin",
                paraphraseRejectionReason: "Raw transcript inserted instead: 22 words became 14.",
                rejectedCleanup: "Temizlenmiş metin."
            ),
            to: directory
        )

        let decoded = try Self.decodeLines(from: directory)
        #expect(decoded.count == 1)
        #expect(decoded[0].rejectedCleanup == "Temizlenmiş metin.")
        #expect(decoded[0].paraphraseRejectionReason?.contains("22 words became 14") == true)
    }

    @Test("an accepted cleanup writes no rejected candidate")
    func acceptedCleanupWritesNoRejectedCandidate() throws {
        let directory = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try DictationLog.append(Self.makeRecord(), to: directory)

        let decoded = try Self.decodeLines(from: directory)
        #expect(decoded[0].rejectedCleanup == nil)
    }

    /// The reason is prose and the concern is data, and only the data can be counted. Counting how
    /// often the guard flags a term by matching "introduced a word that was not spoken" would break
    /// the first time that sentence changed, so the term travels as a field.
    @Test("a guard concern survives the round trip as data, with its kind and its term")
    func guardConcernRoundTrips() throws {
        let directory = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try DictationLog.append(
            Self.makeRecord(
                guardConcern: ParaphraseGuard.Concern(kind: .introducedWord, term: "optimize")
            ),
            to: directory
        )

        let decoded = try Self.decodeLines(from: directory)
        #expect(decoded[0].guardConcern?.kind == .introducedWord)
        #expect(decoded[0].guardConcern?.term == "optimize")
    }

    /// This file is append-only and predates the field, so a line without it is an older record and
    /// not a corrupt one. It has to decode, or every dictation logged before today disappears from
    /// the history list and from the ledger's read.
    @Test("a line written before the concern field existed still decodes")
    func olderLineWithoutTheConcernFieldStillDecodes() throws {
        let directory = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let olderLine = """
            {"timestamp":"2026-08-18T16:53:28Z","mode":"dictate","duration":6.5,\
            "rawTranscript":"ham metin","finalText":"Ham metin.","transcriptionModelId":"whisper-large-v3",\
            "cleanupModelId":"openai/gpt-oss-120b","timings":{"captureMs":1,"encodeMs":1,"transcribeMs":1,\
            "cleanupMs":1,"insertMs":1,"totalMs":5}}
            """
        try Data("\(olderLine)\n".utf8).write(to: DictationLog.fileURL(in: directory))

        let decoded = DictationLog.readAll(from: directory)
        #expect(decoded.count == 1)
        #expect(decoded[0].guardConcern == nil)
        #expect(decoded[0].rawTranscript == "ham metin")
    }

    @Test("the directory is created on first append with mode 0700")
    func directoryIsCreatedOnFirstAppendWithMode0700() throws {
        let directory = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(!FileManager.default.fileExists(atPath: directory.path))

        try DictationLog.append(Self.makeRecord(), to: directory)

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = attributes[.posixPermissions] as? Int
        #expect(permissions == 0o700)
    }

    @Test("trimming keeps only the newest records, oldest first dropped")
    func trimmingKeepsOnlyTheNewestRecords() throws {
        let directory = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldest = Self.makeRecord(rawTranscript: "en eski", finalText: "En eski.")
        let middle = Self.makeRecord(rawTranscript: "orta", finalText: "Orta.")
        let newest = Self.makeRecord(rawTranscript: "en yeni", finalText: "En yeni.")
        try DictationLog.append(oldest, to: directory)
        try DictationLog.append(middle, to: directory)
        try DictationLog.append(newest, to: directory)

        try DictationLog.trim(to: 2, in: directory)

        let decoded = try Self.decodeLines(from: directory)
        #expect(decoded == [middle, newest])
    }

    @Test("retaining audio copies the source file under audio/ with mode 0700 on the directory")
    func retainingAudioCopiesUnderAudioDirectory() throws {
        let directory = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceAudio = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationLogTests-source-\(UUID().uuidString).m4a")
        try Data("dummy audio bytes".utf8).write(to: sourceAudio)
        defer { try? FileManager.default.removeItem(at: sourceAudio) }

        let destination = try DictationLog.retainAudio(from: sourceAudio, timestamp: Date(), in: directory)

        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(destination.pathExtension == "m4a")
        #expect(try Data(contentsOf: destination) == Data("dummy audio bytes".utf8))

        let attributes = try FileManager.default.attributesOfItem(
            atPath: DictationLog.audioDirectory(in: directory).path
        )
        let permissions = attributes[.posixPermissions] as? Int
        #expect(permissions == 0o700)
    }

    /// A directory of this test's own, so nothing here touches the user's real `log.jsonl` and no
    /// two tests in this suite can race each other under Swift Testing's default parallel
    /// execution.
    private static func makeScratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MyDikteDictationLogTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func makeRecord(
        rawTranscript: String = "ham metin",
        finalText: String = "Ham metin.",
        audioPath: URL? = URL(fileURLWithPath: "/tmp/does-not-need-to-exist.m4a"),
        paraphraseRejectionReason: String? = nil,
        rejectedCleanup: String? = nil,
        guardConcern: ParaphraseGuard.Concern? = nil
    ) -> DictationRecord {
        DictationRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            mode: .dictate,
            audioPath: audioPath,
            duration: 3.4,
            rawTranscript: rawTranscript,
            finalText: finalText,
            paraphraseRejectionReason: paraphraseRejectionReason,
            rejectedCleanup: rejectedCleanup,
            guardConcern: guardConcern,
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

    private static func decodeLines(from directory: URL) throws -> [DictationRecord] {
        let data = try Data(contentsOf: DictationLog.fileURL(in: directory))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try data
            .split(separator: UInt8(ascii: "\n"))
            .map { try decoder.decode(DictationRecord.self, from: Data($0)) }
    }
}
