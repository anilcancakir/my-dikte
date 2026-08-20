import Foundation

/// The single owner of every user-facing toggle in this plan. The field list was closed after the
/// original steps shipped, and stayed closed until Mode 2's prompt-toggle shortcut turned out to be
/// the one shortcut belonging to the feature the user cares most about that they could not
/// reconfigure: `promptToggleShortcut` reopened it deliberately, for that reason alone, and it stayed
/// closed again afterward. `stopOnReturnOrSpace` reopened it a second time on the same footing: it
/// governs a gesture that watches two keys every application depends on, so a way to turn it off has to
/// exist without touching code. Persists as JSON to
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
        case elevenLabs

        /// The `KeychainStore` account name for this provider's API key.
        var keychainAccount: String {
            switch self {
            case .groq:
                return "transcription-groq"
            case .openAI:
                return "transcription-openai"
            case .openRouter:
                return "transcription-openrouter"
            case .elevenLabs:
                return "transcription-elevenlabs"
            }
        }

        /// The model this provider transcribes with when the model id field is left empty.
        ///
        /// Per provider rather than one shared constant, because the ids are not interchangeable:
        /// sending `whisper-large-v3` to ElevenLabs is an HTTP 422, and the pane's grey placeholder
        /// has to name the model the next dictation will actually use.
        var defaultModelId: String {
            switch self {
            case .groq, .openRouter:
                return "whisper-large-v3"
            case .openAI:
                return "gpt-4o-transcribe"
            case .elevenLabs:
                return "scribe_v2"
            }
        }
    }

    /// Where the words in the indicator come from while the user is still speaking.
    ///
    /// Two backends rather than a bool, because they differ in kind and not only in quality. Apple's
    /// `SFSpeechRecognizer` runs on device, costs nothing, and works with no network; ElevenLabs
    /// streams the microphone to a hosted model, is billed per audio hour, and needs a connection.
    /// Measured on four real recordings, ElevenLabs reads Turkish technical speech visibly better
    /// while it is still arriving, and that is the whole point of a preview. Apple stays the default
    /// because a preview must never be the reason a dictation costs money or leaves the machine.
    enum LivePreviewProvider: String, Codable, CaseIterable {
        case apple
        case elevenLabs

        /// The `KeychainStore` account the realtime stream authenticates with. The batch and the
        /// realtime paths deliberately share one ElevenLabs account: it is one vendor, one key, and
        /// a second account would only mean entering the same secret twice.
        var keychainAccount: String? {
            switch self {
            case .apple:
                return nil
            case .elevenLabs:
                return TranscriptionProvider.elevenLabs.keychainAccount
            }
        }

        /// The label in the picker. The raw values are Swift case names, and "apple" alone does not
        /// say that the choice is between running on this machine and paying per hour.
        var displayName: String {
            switch self {
            case .apple:
                return "Apple, on device"
            case .elevenLabs:
                return "ElevenLabs, realtime"
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
    /// Which backend the live preview streams through. Reopened the field list for the third time,
    /// and for the same kind of reason as `stopOnReturnOrSpace`: this is the only setting in the app
    /// that decides whether a feature spends money and sends microphone audio off the machine, so it
    /// cannot live in code. Defaults to `.apple`, which is free and on device.
    var livePreviewProvider: LivePreviewProvider
    /// Whether a paraphrase concern lets the cleanup through (advisory) or discards it in favour of
    /// the raw transcript (strict). Advisory unless it is turned off, on the strength of a
    /// measurement rather than a preference: over one day of real use the guard rejected three
    /// correct cleanups and caught no genuine paraphrase. Strict stays reachable, because the
    /// measurement can change and this is not a one-way door.
    var advisoryParaphraseGuard: Bool
    /// Whether a bare Return or Space ends a recording that a keyed shortcut started. On unless it is
    /// turned off: reaching back for a two-modifier chord to stop is the awkwardness it removes, and the
    /// two keys are watched only while a recording is in flight, so what leaving it on costs is bounded
    /// by the length of a dictation. `Hotkeys/ShortcutCoordinator.swift` owns the gesture and the
    /// limitation that comes with it (secure input hides the keys from the tap).
    var stopOnReturnOrSpace: Bool

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
        livePreviewProvider: .apple,
        advisoryParaphraseGuard: true,
        stopOnReturnOrSpace: true
    )
}

extension Settings {
    /// Decodes every field strictly except `advisoryParaphraseGuard`, `stopOnReturnOrSpace` and
    /// `livePreviewProvider`, which fall back to their defaults when the file does not carry them.
    ///
    /// The general rule for this file stands: a file that will not decode is replaced by defaults,
    /// because a background app must not die on a corrupt settings file. These two keys are exempt
    /// because they are the only keys an already-written file can be missing, and treating that as
    /// corruption would take the user's glossary with it: the measured six-term glossary would become
    /// an empty one on the first launch after a field was added, which is worse dictation rather
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
        livePreviewProvider = try container.decodeIfPresent(LivePreviewProvider.self, forKey: .livePreviewProvider)
            ?? Settings.default.livePreviewProvider
        advisoryParaphraseGuard = try container.decodeIfPresent(Bool.self, forKey: .advisoryParaphraseGuard)
            ?? Settings.default.advisoryParaphraseGuard
        stopOnReturnOrSpace = try container.decodeIfPresent(Bool.self, forKey: .stopOnReturnOrSpace)
            ?? Settings.default.stopOnReturnOrSpace
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
