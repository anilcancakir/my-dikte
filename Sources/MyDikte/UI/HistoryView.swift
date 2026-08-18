import AppKit
import SwiftUI

/// One dictation as `HistoryView` renders it: the record itself plus its position in the on-disk
/// JSONL file, oldest first, which `HistoryEntryList.delete(fileIndex:from:)` needs to remove
/// exactly this line and no other.
struct HistoryEntry: Identifiable, Equatable {
    let fileIndex: Int
    let record: DictationRecord

    var id: Int { fileIndex }
}

/// Failures reading or rewriting `log.jsonl` from the History window. `DictationLog` (Step 14)
/// exposes no delete of its own and this wave leaves that file alone, so `HistoryEntryList`
/// operates on the raw lines directly rather than decoding and re-encoding every record, which
/// would risk silently reformatting the JSON of records a delete was never asked to touch.
enum HistoryError: Error, LocalizedError {
    case readFailed(underlying: Error)
    case writeFailed(underlying: Error)
    case entryNotFound

    var errorDescription: String? {
        switch self {
        case .readFailed(let underlying):
            return "Failed to read log.jsonl: \(underlying.localizedDescription)"
        case .writeFailed(let underlying):
            return "Failed to update log.jsonl: \(underlying.localizedDescription)"
        case .entryNotFound:
            return "That dictation no longer exists in the log."
        }
    }
}

/// Reads and edits the JSONL log for `HistoryView`. Pure I/O with no SwiftUI dependency, so both
/// halves are directly testable. Every entry point takes a `directory:` parameter defaulting to
/// the real log, matching `DictationLog`'s own pattern, so no test here ever touches the user's
/// own history.
enum HistoryEntryList {
    /// Every record in `directory`, newest first, each paired with its oldest-first position on
    /// disk so a later `delete(fileIndex:from:)` call addresses the correct line.
    static func load(from directory: URL = DictationLog.defaultDirectory) -> [HistoryEntry] {
        Array(
            DictationLog.readAll(from: directory)
                .enumerated()
                .map { HistoryEntry(fileIndex: $0.offset, record: $0.element) }
                .reversed()
        )
    }

    /// Removes exactly the line at `fileIndex` (oldest-first, as `load` reports it) and rewrites
    /// the rest of the file untouched, working on raw bytes the same way `DictationLog.append`
    /// and `DictationLog.trim` split lines, so this never disturbs a record it was not asked to
    /// remove.
    static func delete(fileIndex: Int, from directory: URL = DictationLog.defaultDirectory) throws {
        let url = DictationLog.fileURL(in: directory)

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw HistoryError.readFailed(underlying: error)
        }

        var lines = data.split(separator: UInt8(ascii: "\n"))
        guard lines.indices.contains(fileIndex) else {
            throw HistoryError.entryNotFound
        }
        lines.remove(at: fileIndex)

        do {
            var newData = Data()
            for line in lines {
                newData.append(contentsOf: line)
                newData.append(contentsOf: [UInt8(ascii: "\n")])
            }
            try newData.write(to: url, options: .atomic)
        } catch {
            throw HistoryError.writeFailed(underlying: error)
        }
    }
}

/// The dictation history window's content: the JSONL log from Step 14, newest first, with the raw
/// transcript revealed on selection so a bad cleanup is visible next to what was actually said.
/// Copy-to-clipboard and delete live in the detail toolbar.
struct HistoryView: View {
    @State private var entries: [HistoryEntry] = []
    @State private var selectedID: HistoryEntry.ID?
    @State private var errorMessage: String?

    var body: some View {
        NavigationSplitView {
            List(entries, selection: $selectedID) { entry in
                HistoryRow(record: entry.record)
                    .tag(entry.id)
            }
            .navigationTitle("History")
            .frame(minWidth: 300)
            .overlay {
                if entries.isEmpty {
                    Text("No dictations yet.")
                        .foregroundStyle(.secondary)
                }
            }
        } detail: {
            if let selected = entries.first(where: { $0.id == selectedID }) {
                HistoryDetail(
                    entry: selected,
                    onCopy: { copyToClipboard(selected.record.finalText) },
                    onDelete: { delete(selected) }
                )
            } else {
                Text("Select a dictation to see its raw transcript.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear(perform: reload)
        .alert(
            "History",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
            actions: { Button("OK") {} },
            message: { Text(errorMessage ?? "") }
        )
    }

    private func reload() {
        entries = HistoryEntryList.load()
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func delete(_ entry: HistoryEntry) {
        do {
            try HistoryEntryList.delete(fileIndex: entry.fileIndex)
            if selectedID == entry.id {
                selectedID = nil
            }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Row and detail

private struct HistoryRow: View {
    let record: DictationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(Self.timestampFormatter.string(from: record.timestamp))
                    .font(.subheadline)
                Spacer()
                Text(record.mode == .dictate ? "Dictate" : "Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(record.finalText)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(
                "\(Self.durationFormatter.string(from: NSNumber(value: record.duration)) ?? "-")s duration, "
                    + "\(Int(record.timings.totalMs)) ms total"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let durationFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 1
        return formatter
    }()
}

private struct HistoryDetail: View {
    let entry: HistoryEntry
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Final text").font(.headline)
                Text(entry.record.finalText)
                    .textSelection(.enabled)

                if let reason = entry.record.paraphraseRejectionReason {
                    Text("Cleanup rejected: \(reason)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Divider()

                Text("Raw transcript").font(.headline)
                Text(entry.record.rawTranscript)
                    .textSelection(.enabled)

                Divider()

                Text("Transcription: \(entry.record.transcriptionModelId), cleanup: \(entry.record.cleanupModelId)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Copy", action: onCopy)
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
    }
}
