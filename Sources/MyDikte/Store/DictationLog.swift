import Foundation

/// A single dictation, one line of `~/Library/Application Support/MyDikte/log.jsonl`. Every field
/// exists because two deferred decisions read this file instead of the app: choosing the cleanup
/// model becomes an offline replay over real dictations rather than a benchmark over synthetic
/// clips, and testing whether a single audio-in call could replace transcription and cleanup
/// becomes a diff against transcripts already on disk. Both need the audio path, the raw
/// transcript and the per-stage timings in the same record, which is why none of those three is
/// optional here.
struct DictationRecord: Codable, Equatable {
    /// Which pipeline produced this record: a plain dictation, or an assistant-style prompt.
    enum Mode: String, Codable, Equatable {
        case dictate
        case prompt
    }

    /// Wall-clock cost of every pipeline stage, in milliseconds. A stage the run never reached
    /// (cleanup disabled, insertion skipped after a rejection) is recorded as `0`, never omitted,
    /// so an offline reader can tell "not run" from "not measured" instead of treating a missing
    /// key as a bug in the reader.
    struct Timings: Codable, Equatable {
        let captureMs: Double
        let encodeMs: Double
        let transcribeMs: Double
        let cleanupMs: Double
        let insertMs: Double
        let totalMs: Double

        init(
            captureMs: Double,
            encodeMs: Double,
            transcribeMs: Double,
            cleanupMs: Double,
            insertMs: Double,
            totalMs: Double
        ) {
            self.captureMs = captureMs
            self.encodeMs = encodeMs
            self.transcribeMs = transcribeMs
            self.cleanupMs = cleanupMs
            self.insertMs = insertMs
            self.totalMs = totalMs
        }
    }

    let timestamp: Date
    let mode: Mode
    /// The retained audio file's location under `audio/`, or `nil` when `Settings.retainAudio` was
    /// `false` for this dictation. Never the API key or any request header: neither ever enters
    /// this file.
    let audioPath: URL?
    let duration: Double
    let rawTranscript: String
    let finalText: String
    /// `nil` when the paraphrase guard accepted the cleanup or was never run; the sentence the user
    /// was shown otherwise. Presence of a sentence is how a reader tells "something was said about
    /// this dictation" from "nothing was", rather than a separate boolean that could disagree with it.
    ///
    /// It no longer implies a rejection: in advisory mode it carries the concern while `finalText`
    /// still holds the cleanup. `rejectedCleanup` is what distinguishes the two, and `guardConcern`
    /// is what a reader should count.
    let paraphraseRejectionReason: String?
    /// The cleanup the paraphrase guard turned down, when it turned one down. `nil` both when
    /// nothing was rejected and when the cleanup call itself failed, since there was no candidate.
    ///
    /// It is here for the same reason `rawTranscript` is: a reason string quotes word counts and
    /// cannot say whether the guard was right. A measured four-out-of-four rejection turned out to
    /// be the guard refusing the exact glossary repair the cleanup prompt asks for, and that stayed
    /// invisible for a whole wave because the candidate was discarded at the moment it was judged.
    /// Tuning the guard's thresholds against real dictations is only possible if this survives.
    let rejectedCleanup: String?
    /// What the paraphrase guard found, as data: which check fired and the term at issue. This is
    /// what makes a term countable across the file, which is what `GuardConcernLedger` needs;
    /// recovering a term by matching `paraphraseRejectionReason` would break the first time that
    /// sentence was reworded.
    ///
    /// Optional because this file is append-only and older lines predate the field: a missing key
    /// here means an older record, not a corrupt file. That is the opposite of `Settings`, where a
    /// file that will not decode is replaced by defaults, and it is why this one field is optional
    /// rather than the file being versioned.
    let guardConcern: ParaphraseGuard.Concern?
    let transcriptionModelId: String
    let cleanupModelId: String
    let timings: Timings

    init(
        timestamp: Date,
        mode: Mode,
        audioPath: URL?,
        duration: Double,
        rawTranscript: String,
        finalText: String,
        paraphraseRejectionReason: String?,
        rejectedCleanup: String?,
        guardConcern: ParaphraseGuard.Concern? = nil,
        transcriptionModelId: String,
        cleanupModelId: String,
        timings: Timings
    ) {
        self.timestamp = timestamp
        self.mode = mode
        self.audioPath = audioPath
        self.duration = duration
        self.rawTranscript = rawTranscript
        self.finalText = finalText
        self.paraphraseRejectionReason = paraphraseRejectionReason
        self.rejectedCleanup = rejectedCleanup
        self.guardConcern = guardConcern
        self.transcriptionModelId = transcriptionModelId
        self.cleanupModelId = cleanupModelId
        self.timings = timings
    }
}

/// Failures writing to `log.jsonl` or retaining a dictation's audio file.
enum DictationLogError: Error, LocalizedError {
    case writeFailed(underlying: Error)
    case retainAudioFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let underlying):
            return "Failed to write log.jsonl: \(underlying.localizedDescription)"
        case .retainAudioFailed(let underlying):
            return "Failed to retain the dictation's audio file: \(underlying.localizedDescription)"
        }
    }
}

/// The append-only JSONL dictation history at `~/Library/Application Support/MyDikte/log.jsonl`,
/// plus the audio files it retains alongside it under `audio/`. Every entry point takes a
/// `directory` parameter defaulting to the real one, so a test can point them at a temporary path
/// instead of ever touching the user's own log, the same fix Wave 2 made to `Settings.load`/`save`
/// after the shared-file race made that suite flaky under Swift Testing's parallel execution.
enum DictationLog {
    static var defaultDirectory: URL { BundleInfo.applicationSupportDirectory }

    /// The on-disk location for the log file inside `directory`.
    static func fileURL(in directory: URL = DictationLog.defaultDirectory) -> URL {
        directory.appendingPathComponent("log.jsonl")
    }

    /// The retained-audio directory inside `directory`.
    static func audioDirectory(in directory: URL = DictationLog.defaultDirectory) -> URL {
        directory.appendingPathComponent("audio", isDirectory: true)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// A filename-safe timestamp for retained audio files: colons are valid in an APFS path but
    /// awkward in Finder and in shell one-liners, so this avoids them rather than working around
    /// them later.
    private static let audioFilenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    /// Appends `record` as one JSON line, creating `directory` with owner-only (`0700`)
    /// permissions on first use. Opens the file for appending rather than reading it back and
    /// rewriting it whole, so a crash mid-write can corrupt at most the line being written, never
    /// an earlier one.
    static func append(_ record: DictationRecord, to directory: URL = DictationLog.defaultDirectory) throws {
        do {
            try createDirectoryIfNeeded(directory)

            var data = try encoder.encode(record)
            data.append(contentsOf: [UInt8(ascii: "\n")])

            let url = fileURL(in: directory)
            if let handle = FileHandle(forWritingAtPath: url.path) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            throw DictationLogError.writeFailed(underlying: error)
        }
    }

    /// Reads every record currently on disk, skipping a malformed line rather than failing the
    /// whole read on one bad line among many good ones. Returns an empty array when the file does
    /// not exist yet.
    static func readAll(from directory: URL = DictationLog.defaultDirectory) -> [DictationRecord] {
        guard let data = try? Data(contentsOf: fileURL(in: directory)) else {
            return []
        }
        return data
            .split(separator: UInt8(ascii: "\n"))
            .compactMap { line in try? decoder.decode(DictationRecord.self, from: Data(line)) }
    }

    /// Drops the oldest records once the file holds more than `limit`, matching
    /// `Settings.historyLimit`, and removes the audio files that belonged only to the dropped
    /// records so retained audio never outlives its own log entry. `limit <= 0` keeps everything.
    /// Trimming rewrites the whole file, unlike `append`: dropping oldest-first is not an
    /// append-only operation by nature.
    static func trim(to limit: Int, in directory: URL = DictationLog.defaultDirectory) throws {
        guard limit > 0 else { return }

        let all = readAll(from: directory)
        guard all.count > limit else { return }

        let dropped = all.prefix(all.count - limit)
        let kept = all.suffix(limit)

        do {
            var data = Data()
            for record in kept {
                data.append(try encoder.encode(record))
                data.append(contentsOf: [UInt8(ascii: "\n")])
            }
            try data.write(to: fileURL(in: directory), options: .atomic)
        } catch {
            throw DictationLogError.writeFailed(underlying: error)
        }

        for record in dropped {
            if let audioPath = record.audioPath {
                try? FileManager.default.removeItem(at: audioPath)
            }
        }
    }

    /// Copies `sourceAudioURL` (the encoder's already-produced audio file) into `audio/` under a
    /// timestamp-derived name, creating that directory with owner-only (`0700`) permissions on
    /// first use. Returns the retained file's URL, for `DictationRecord.audioPath`. Copies rather
    /// than moves, since the caller's temporary file is not this type's to assume ownership of.
    static func retainAudio(
        from sourceAudioURL: URL,
        timestamp: Date,
        in directory: URL = DictationLog.defaultDirectory
    ) throws -> URL {
        let audioDir = audioDirectory(in: directory)
        do {
            try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: audioDir.path)

            let baseName = "\(audioFilenameFormatter.string(from: timestamp))-\(UUID().uuidString.prefix(8))"
            let destination = audioDir
                .appendingPathComponent(baseName)
                .appendingPathExtension(sourceAudioURL.pathExtension)
            try FileManager.default.copyItem(at: sourceAudioURL, to: destination)
            return destination
        } catch {
            throw DictationLogError.retainAudioFailed(underlying: error)
        }
    }

    /// Creates `directory` with owner-only (`0700`) permissions the first time anything is
    /// appended, since the log carries raw transcripts and, when retention is on, paths to the
    /// user's own voice.
    private static func createDirectoryIfNeeded(_ directory: URL) throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}
