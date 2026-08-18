import Foundation

/// The single owner of every user-facing toggle in this plan: the field list is closed and
/// complete here, and no later step grows it, because `Store/Settings.swift` appears in no other
/// step's `Files` list. Persists as JSON to
/// `~/Library/Application Support/MyDikte/settings.json` with `0600` permissions. API keys never
/// live in this file; they go through `KeychainStore` instead.
struct Settings: Codable, Equatable {
    /// A keyboard shortcut expressed as a modifier mask plus an optional key code, so a
    /// modifier-only chord (push-to-talk) and a modifier-plus-key chord (toggle, cancel) share
    /// one representation without depending on the `Hotkeys` area, which this step does not
    /// touch and which has not landed yet in this wave.
    struct KeyChord: Codable, Equatable {
        let modifierFlags: UInt
        let keyCode: UInt16?

        init(modifierFlags: UInt, keyCode: UInt16? = nil) {
            self.modifierFlags = modifierFlags
            self.keyCode = keyCode
        }
    }

    /// The transcription backend this app talks to. Each case owns a distinct Keychain account,
    /// per the Wave 1 amendment: one account per provider rather than a single shared
    /// `transcription` account, so switching providers never overwrites a previously stored key.
    enum TranscriptionProvider: String, Codable, CaseIterable {
        case groq
        case openAI
        case openRouter

        /// The `KeychainStore` account name for this provider's API key.
        var keychainAccount: String {
            switch self {
            case .groq:
                return "transcription-groq"
            case .openAI:
                return "transcription-openai"
            case .openRouter:
                return "transcription-openrouter"
            }
        }
    }

    var pushToTalkChord: KeyChord
    var toggleShortcut: KeyChord
    var cancelShortcut: KeyChord
    var glossaryTerms: [String]
    var transcriptionProvider: TranscriptionProvider
    var transcriptionModelId: String
    var cleanupModelId: String
    var cleanupEndpoint: String
    var rewriteEndpoint: String
    var autoInsert: Bool
    var historyLimit: Int
    var retainAudio: Bool
    var audioCuesEnabled: Bool

    /// The `KeychainStore` account for the Step 13 cleanup and rewrite client, per the Wave 1
    /// amendment.
    static let cleanupKeychainAccount = "cleanup"

    static let `default` = Settings(
        pushToTalkChord: KeyChord(modifierFlags: 0),
        toggleShortcut: KeyChord(modifierFlags: 0),
        cancelShortcut: KeyChord(modifierFlags: 0),
        glossaryTerms: [],
        transcriptionProvider: .groq,
        transcriptionModelId: "",
        cleanupModelId: "",
        cleanupEndpoint: "https://api.openai.com/v1/chat/completions",
        rewriteEndpoint: "https://api.openai.com/v1/chat/completions",
        autoInsert: true,
        historyLimit: 50,
        retainAudio: true,
        audioCuesEnabled: true
    )
}

/// Failures persisting `Settings` to disk. Reading never throws: a missing or malformed file
/// falls back to `Settings.default` instead, because a background dictation app must not crash
/// on a corrupt settings file it can simply replace.
enum SettingsError: Error, LocalizedError {
    case writeFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let underlying):
            return "Failed to write settings.json: \(underlying.localizedDescription)"
        }
    }
}

extension Settings {
    /// The fixed on-disk location for the settings file.
    static let fileURL: URL = BundleInfo.applicationSupportDirectory.appendingPathComponent("settings.json")

    /// Loads settings from disk, falling back to `Settings.default` when the file is missing or
    /// cannot be decoded, rather than crashing on a corrupt or partially written file.
    static func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL) else {
            return .default
        }
        guard let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return .default
        }
        return settings
    }

    /// Writes this value to `Settings.fileURL` with owner-only (`0600`) permissions, since the
    /// file sits alongside no keys but still carries model ids and endpoints the user chose.
    func save() throws {
        do {
            try FileManager.default.createDirectory(
                at: BundleInfo.applicationSupportDirectory,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(self)
            try data.write(to: Self.fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: Self.fileURL.path
            )
        } catch {
            throw SettingsError.writeFailed(underlying: error)
        }
    }
}
