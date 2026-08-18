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
            pushToTalkChord: Settings.KeyChord(modifierFlags: 0x0008_0000),
            toggleShortcut: Settings.KeyChord(modifierFlags: 0x0008_0000, keyCode: 49),
            cancelShortcut: Settings.KeyChord(modifierFlags: 0x0004_0000, keyCode: 53),
            glossaryTerms: ["PyQt", "cache invalidation"],
            transcriptionProvider: .openRouter,
            transcriptionModelId: "whisper-large-v3",
            cleanupModelId: "gpt-5-mini",
            cleanupEndpoint: "https://api.openai.com/v1/chat/completions",
            rewriteEndpoint: "https://api.openai.com/v1/chat/completions",
            autoInsert: false,
            historyLimit: 25,
            retainAudio: false,
            audioCuesEnabled: false
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        #expect(decoded == settings)
        #expect(decoded.retainAudio == false)
        #expect(decoded.audioCuesEnabled == false)
    }

    @Test("default settings have retainAudio and audioCuesEnabled both true")
    func defaultsMatchThePlan() {
        #expect(Settings.default.retainAudio == true)
        #expect(Settings.default.audioCuesEnabled == true)
    }

    @Test("a missing settings file loads defaults")
    func missingFileLoadsDefaults() throws {
        let originalData = try? Data(contentsOf: Settings.fileURL)
        defer { restore(originalData) }

        try? FileManager.default.removeItem(at: Settings.fileURL)

        #expect(Settings.load() == Settings.default)
    }

    @Test("a truncated or malformed settings file loads defaults rather than crashing")
    func malformedFileLoadsDefaults() throws {
        let originalData = try? Data(contentsOf: Settings.fileURL)
        defer { restore(originalData) }

        try FileManager.default.createDirectory(
            at: BundleInfo.applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        try Data("{ this is not valid json".utf8).write(to: Settings.fileURL)

        #expect(Settings.load() == Settings.default)
    }

    @Test("saving writes the file with owner-only permissions and load reads it back")
    func saveWritesOwnerOnlyPermissionsAndLoadRoundTrips() throws {
        let originalData = try? Data(contentsOf: Settings.fileURL)
        defer { restore(originalData) }

        var settings = Settings.default
        settings.historyLimit = 99
        settings.retainAudio = false

        try settings.save()

        let attributes = try FileManager.default.attributesOfItem(atPath: Settings.fileURL.path)
        let permissions = attributes[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(Settings.load() == settings)
    }

    /// Restores whatever `settings.json` held before a test ran, so a real settings file on this
    /// machine is never permanently overwritten by a test run.
    private func restore(_ data: Data?) {
        guard let data else {
            try? FileManager.default.removeItem(at: Settings.fileURL)
            return
        }
        try? data.write(to: Settings.fileURL)
    }
}
