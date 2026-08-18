import Foundation

/// The single owner of every user-facing toggle in this plan. The field list was closed after the
/// original steps shipped, and stayed closed until Mode 2's prompt-toggle shortcut turned out to be
/// the one shortcut belonging to the feature the user cares most about that they could not
/// reconfigure: `promptToggleShortcut` reopened it deliberately, for that reason alone, and it stays
/// closed again afterward. Persists as JSON to
/// `~/Library/Application Support/MyDikte/settings.json` with `0600` permissions. API keys never
/// live in this file; they go through `KeychainStore` instead.
struct Settings: Codable, Equatable {
    /// A keyboard shortcut expressed in primitives only, so a modifier-only chord (push-to-talk)
    /// and a modifier-plus-key chord (toggle, cancel) share one representation and this file still
    /// depends on no other area. `Hotkeys/ShortcutBinding.swift` owns every mapping from these
    /// primitives onto the types that actually register a shortcut.
    ///
    /// `modifierKeys` is **ordered** and names **physical** keys (`ShortcutCoordinator.ModifierKey`
    /// raw values, for example `"rightOption"`), because push-to-talk is an ordered pair of
    /// side-specific keys: right Option then right Command is a different gesture from right Command
    /// then right Option, and left Option is a different key from right Option. A modifier bitmask
    /// expressed neither, so a recorded chord could not round-trip through the file at all.
    struct KeyChord: Codable, Equatable {
        let modifierKeys: [String]
        let keyCode: UInt16?

        init(modifierKeys: [String], keyCode: UInt16? = nil) {
            self.modifierKeys = modifierKeys
            self.keyCode = keyCode
        }

        /// No shortcut recorded, which resolves to the `Hotkeys` default rather than to nothing.
        static let unset = KeyChord(modifierKeys: [])

        /// A chord with no modifier is not a shortcut this app registers: the push-to-talk gesture
        /// is modifiers only, and a global hot key with no modifier would take a bare key away from
        /// every app in the session.
        var isEmpty: Bool {
            modifierKeys.isEmpty
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
    var promptToggleShortcut: KeyChord
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
    /// The on-device live preview in the indicator while recording. On unless it is turned off:
    /// it costs no API call and no network, and it is the feature the user asked for by name.
    var livePreviewEnabled: Bool
    /// Whether a paraphrase concern lets the cleanup through (advisory) or discards it in favour of
    /// the raw transcript (strict). Advisory unless it is turned off, on the strength of a
    /// measurement rather than a preference: over one day of real use the guard rejected three
    /// correct cleanups and caught no genuine paraphrase. Strict stays reachable, because the
    /// measurement can change and this is not a one-way door.
    var advisoryParaphraseGuard: Bool

    static let `default` = Settings(
        pushToTalkChord: .unset,
        toggleShortcut: .unset,
        cancelShortcut: .unset,
        promptToggleShortcut: .unset,
        glossaryTerms: [],
        transcriptionProvider: .groq,
        transcriptionModelId: "",
        cleanupModelId: "",
        cleanupEndpoint: "",
        rewriteEndpoint: "",
        autoInsert: true,
        historyLimit: 50,
        retainAudio: true,
        audioCuesEnabled: true,
        livePreviewEnabled: true,
        advisoryParaphraseGuard: true
    )
}

extension Settings {
    /// Decodes every field strictly except `advisoryParaphraseGuard`, which falls back to the default
    /// when the file does not carry it.
    ///
    /// The general rule for this file stands: a file that will not decode is replaced by defaults,
    /// because a background app must not die on a corrupt settings file. This one key is exempt
    /// because it is the only key an already-written file can be missing, and treating that as
    /// corruption would take the user's glossary with it: the measured six-term glossary would become
    /// an empty one on the first launch after the field was added, which is worse dictation rather
    /// than a reset toggle.
    ///
    /// Written in an extension rather than in the type's body so that the memberwise initialiser
    /// survives; `Settings.default` and the tests are built with it.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        pushToTalkChord = try container.decode(KeyChord.self, forKey: .pushToTalkChord)
        toggleShortcut = try container.decode(KeyChord.self, forKey: .toggleShortcut)
        cancelShortcut = try container.decode(KeyChord.self, forKey: .cancelShortcut)
        promptToggleShortcut = try container.decode(KeyChord.self, forKey: .promptToggleShortcut)
        glossaryTerms = try container.decode([String].self, forKey: .glossaryTerms)
        transcriptionProvider = try container.decode(TranscriptionProvider.self, forKey: .transcriptionProvider)
        transcriptionModelId = try container.decode(String.self, forKey: .transcriptionModelId)
        cleanupModelId = try container.decode(String.self, forKey: .cleanupModelId)
        cleanupEndpoint = try container.decode(String.self, forKey: .cleanupEndpoint)
        rewriteEndpoint = try container.decode(String.self, forKey: .rewriteEndpoint)
        autoInsert = try container.decode(Bool.self, forKey: .autoInsert)
        historyLimit = try container.decode(Int.self, forKey: .historyLimit)
        retainAudio = try container.decode(Bool.self, forKey: .retainAudio)
        audioCuesEnabled = try container.decode(Bool.self, forKey: .audioCuesEnabled)
        livePreviewEnabled = try container.decode(Bool.self, forKey: .livePreviewEnabled)
        advisoryParaphraseGuard = try container.decodeIfPresent(Bool.self, forKey: .advisoryParaphraseGuard)
            ?? Settings.default.advisoryParaphraseGuard
    }
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
    /// The app's real settings directory. Both `load` and `save` take a directory rather than
    /// reading this constant directly, so a test can point them at a temporary path and never
    /// touch the user's own file. Without that parameter the persistence tests all shared one
    /// global file and raced each other under Swift Testing's default parallel execution, which
    /// made the suite flaky in two different ways: a load finding no file at all, and a load
    /// returning defaults because a sibling test had restored the file mid-run.
    static var defaultDirectory: URL { BundleInfo.applicationSupportDirectory }

    /// The on-disk location for the settings file inside `directory`.
    static func fileURL(in directory: URL = Settings.defaultDirectory) -> URL {
        directory.appendingPathComponent("settings.json")
    }

    /// Loads settings from disk, falling back to `Settings.default` when the file is missing or
    /// cannot be decoded, rather than crashing on a corrupt or partially written file.
    static func load(from directory: URL = Settings.defaultDirectory) -> Settings {
        guard let data = try? Data(contentsOf: fileURL(in: directory)) else {
            return .default
        }
        guard let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return .default
        }
        return settings
    }

    /// Writes this value with owner-only (`0600`) permissions, since the file sits alongside no
    /// keys but still carries model ids and endpoints the user chose.
    func save(to directory: URL = Settings.defaultDirectory) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url: URL = Settings.fileURL(in: directory)
            let data = try JSONEncoder().encode(self)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw SettingsError.writeFailed(underlying: error)
        }
    }
}
