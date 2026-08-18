import Foundation
import Testing

@testable import MyDikte

/// Covers the two pieces Step 10 owns: `KeychainStore`'s round trip over `SecItem`, and
/// `Settings`'s JSON persistence, including the malformed-file fallback to defaults.
///
/// Every test uses a throwaway Keychain account distinct from anything `Settings` actually
/// stores under, and cleans up after itself, so a test run never touches a key the user depends
/// on. No test writes a real API key: only fixed dummy strings.
@Suite("KeychainStore round trip")
struct KeychainStoreTests {
    @Test("storing, reading and deleting a value round-trips")
    func storeReadDelete() {
        let account = "test.SettingsTests.\(UUID().uuidString)"
        defer { KeychainStore.delete(forAccount: account) }

        #expect(KeychainStore.store("dummy-value", forAccount: account))
        #expect(KeychainStore.read(forAccount: account) == .found("dummy-value"))
        #expect(KeychainStore.delete(forAccount: account))
    }

    @Test("reading a deleted account reports missing rather than throwing")
    func readingDeletedAccountReportsMissing() {
        let account = "test.SettingsTests.\(UUID().uuidString)"

        #expect(KeychainStore.store("dummy-value", forAccount: account))
        #expect(KeychainStore.delete(forAccount: account))
        #expect(KeychainStore.read(forAccount: account) == .missing)
    }

    @Test("reading an account that was never stored reports missing")
    func readingUnknownAccountReportsMissing() {
        let account = "test.SettingsTests.never-stored.\(UUID().uuidString)"
        #expect(KeychainStore.read(forAccount: account) == .missing)
    }
}

@Suite("Settings persistence")
struct SettingsPersistenceTests {
    @Test("Settings round-trips through JSON with every field preserved")
    func jsonRoundTripPreservesEveryField() throws {
        let settings = Settings(
            pushToTalkChord: Settings.KeyChord(modifierKeys: ["rightOption", "rightCommand"]),
            toggleShortcut: Settings.KeyChord(modifierKeys: ["leftControl", "leftOption"], keyCode: 49),
            cancelShortcut: Settings.KeyChord(modifierKeys: ["leftControl"], keyCode: 53),
            promptToggleShortcut: Settings.KeyChord(modifierKeys: ["leftControl", "leftShift"], keyCode: 35),
            glossaryTerms: ["PyQt", "cache invalidation"],
            transcriptionProvider: .openRouter,
            transcriptionModelId: "whisper-large-v3",
            cleanupModelId: "gpt-5-mini",
            cleanupEndpoint: "https://api.groq.com/openai/v1/chat/completions",
            rewriteEndpoint: "https://openrouter.ai/api/v1/chat/completions",
            autoInsert: false,
            historyLimit: 25,
            retainAudio: false,
            audioCuesEnabled: false,
            livePreviewEnabled: false,
            advisoryParaphraseGuard: false
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        #expect(decoded == settings)
        #expect(decoded.retainAudio == false)
        #expect(decoded.audioCuesEnabled == false)
        #expect(decoded.livePreviewEnabled == false)
        #expect(decoded.advisoryParaphraseGuard == false)
        #expect(decoded.promptToggleShortcut == settings.promptToggleShortcut)
    }

    /// The guard is advisory unless it is turned off, because the measurement says so: over one day of
    /// real use it rejected three correct cleanups and caught no genuine paraphrase.
    @Test("the paraphrase guard defaults to advisory")
    func advisoryGuardDefaultsToOn() {
        #expect(Settings.default.advisoryParaphraseGuard == true)
    }

    /// A settings file written before this field existed must keep everything else it holds. A strict
    /// decode would throw, `load` would fall back to defaults, and the user's measured six-term
    /// glossary would silently become an empty one, which is a worse dictation rather than a reset
    /// toggle. Only this one key is treated as optional: it is the only key an existing file can be
    /// missing.
    @Test("a settings file written before the advisory field keeps its glossary and gains the default")
    func olderSettingsFileKeepsItsGlossary() throws {
        let directory: URL = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let olderFile = """
            {"pushToTalkChord":{"modifierKeys":[]},"toggleShortcut":{"modifierKeys":[]},\
            "cancelShortcut":{"modifierKeys":[]},"promptToggleShortcut":{"modifierKeys":[]},\
            "glossaryTerms":["Kubernetes","Grafana","PyQt","Speech to Text","LLM","prompt"],\
            "transcriptionProvider":"groq","transcriptionModelId":"","cleanupModelId":"",\
            "cleanupEndpoint":"","rewriteEndpoint":"","autoInsert":true,"historyLimit":50,\
            "retainAudio":true,"audioCuesEnabled":true,"livePreviewEnabled":true}
            """
        try Data(olderFile.utf8).write(to: Settings.fileURL(in: directory))

        let loaded = Settings.load(from: directory)
        #expect(loaded.glossaryTerms.count == 6)
        #expect(loaded.glossaryTerms.contains("PyQt"))
        #expect(loaded.advisoryParaphraseGuard == true)
    }

    /// The push-to-talk gesture is an ordered pair of physical keys, so both the order and the side
    /// have to survive the file. A modifier bitmask expressed neither, which is why a recorded chord
    /// could not be persisted at all before this shape.
    @Test("a chord's order and its side both survive JSON")
    func chordOrderAndSideSurviveJSON() throws {
        let forward = Settings.KeyChord(modifierKeys: ["rightOption", "rightCommand"])
        let reversed = Settings.KeyChord(modifierKeys: ["rightCommand", "rightOption"])
        let otherSide = Settings.KeyChord(modifierKeys: ["leftOption", "rightCommand"])

        let decoded = try JSONDecoder().decode(Settings.KeyChord.self, from: JSONEncoder().encode(forward))

        #expect(decoded == forward)
        #expect(decoded.modifierKeys == ["rightOption", "rightCommand"])
        #expect(decoded != reversed)
        #expect(decoded != otherSide)
    }

    @Test("a modifier-plus-key chord survives JSON with its key code")
    func keyedChordSurvivesJSON() throws {
        let chord = Settings.KeyChord(modifierKeys: ["leftControl", "leftOption"], keyCode: 49)
        let decoded = try JSONDecoder().decode(Settings.KeyChord.self, from: JSONEncoder().encode(chord))

        #expect(decoded == chord)
        #expect(decoded.keyCode == 49)
    }

    @Test("default settings store no shortcut at all, so the Hotkeys defaults own them")
    func defaultsStoreNoShortcut() {
        #expect(Settings.default.pushToTalkChord == Settings.KeyChord.unset)
        #expect(Settings.default.toggleShortcut.isEmpty)
        #expect(Settings.default.cancelShortcut.isEmpty)
        #expect(Settings.default.promptToggleShortcut == Settings.KeyChord.unset)
    }

    @Test("default settings have retainAudio and audioCuesEnabled both true")
    func defaultsMatchThePlan() {
        #expect(Settings.default.retainAudio == true)
        #expect(Settings.default.audioCuesEnabled == true)
    }

    /// The live preview is the feature the user asked for by name, so it is on unless it is turned
    /// off. Off has to mean off completely: no recogniser created and no authorisation requested.
    @Test("the live preview defaults to on")
    func livePreviewDefaultsToOn() {
        #expect(Settings.default.livePreviewEnabled == true)
        #expect(PipelineConfiguration(settings: .default).livePreviewEnabled == true)
    }

    @Test("a missing settings file loads defaults")
    func missingFileLoadsDefaults() throws {
        let directory: URL = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(Settings.load(from: directory) == Settings.default)
    }

    @Test("a truncated or malformed settings file loads defaults rather than crashing")
    func malformedFileLoadsDefaults() throws {
        let directory: URL = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ this is not valid json".utf8).write(to: Settings.fileURL(in: directory))

        #expect(Settings.load(from: directory) == Settings.default)
    }

    @Test("saving writes the file with owner-only permissions and load reads it back")
    func saveWritesOwnerOnlyPermissionsAndLoadRoundTrips() throws {
        let directory: URL = Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var settings = Settings.default
        settings.historyLimit = 99
        settings.retainAudio = false

        try settings.save(to: directory)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: Settings.fileURL(in: directory).path
        )
        let permissions = attributes[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(Settings.load(from: directory) == settings)
    }

    /// A directory of this test's own, so nothing here touches the user's real `settings.json` and
    /// no two tests in this suite can race each other.
    ///
    /// Swift Testing runs tests in parallel by default. An earlier version of this suite shared the
    /// one real settings file and saved-then-restored it around each test, which failed two
    /// different ways depending on interleaving: a load finding no file, and a load returning
    /// defaults because a sibling had already restored the file. Shared mutable global state is the
    /// bug; a per-test path removes it rather than serialising around it.
    private static func makeScratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MyDikteSettingsTests-\(UUID().uuidString)", isDirectory: true)
    }
}

/// The Keys pane writes the cleanup key to whichever account the pipeline will read it from, and
/// that account depends on the configured endpoint. Before this, the pane stored under a fixed
/// `"cleanup"` account no client ever read, so a key typed into the app's own UI was invisible to
/// the pipeline. The mapping is not restated here: it is asserted through the pipeline's own
/// resolver, which is the single source of truth the pane also calls.
@Suite("Cleanup key account derivation")
struct CleanupKeyAccountTests {
    @Test("the untouched default endpoint derives the Groq account, as the pipeline resolves it")
    func defaultEndpointDerivesGroqAccount() {
        let account: String = PipelineConfiguration(settings: .default).chatKeychainAccount(for: .dictate)

        #expect(account == "cleanup-groq")
    }

    @Test("an OpenRouter endpoint derives the OpenRouter account")
    func openRouterEndpointDerivesOpenRouterAccount() {
        var settings = Settings.default
        settings.cleanupEndpoint = "https://openrouter.ai/api/v1/chat/completions"

        let account: String = PipelineConfiguration(settings: settings).chatKeychainAccount(for: .dictate)

        #expect(account == "cleanup-openrouter")
    }

    @Test("the derived account is the one the pipeline reads for the same settings")
    func derivedAccountMatchesTheConsumer() {
        var settings = Settings.default
        settings.cleanupEndpoint = "https://openrouter.ai/api/v1/chat/completions"
        let configuration = PipelineConfiguration(settings: settings)

        #expect(
            configuration.chatKeychainAccount(for: .dictate)
                == PipelineConfiguration.chatKeychainAccount(forEndpoint: configuration.chatEndpoint(for: .dictate))
        )
    }
}
