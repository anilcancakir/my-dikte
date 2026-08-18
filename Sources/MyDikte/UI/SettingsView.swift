import AppKit
import SwiftUI

/// The five settings panes: shortcuts, glossary, models, keys and behaviour. Every field maps to
/// a `Settings` property (Store's closed field list, per the plan's Codebase Conventions) except
/// the two Keychain-backed key fields, which never round-trip through `Settings`.
///
/// Every control saves immediately on change, so `Settings.save(to:)` is always the source of
/// truth on disk and no separate "Save" button can be left unpressed.
struct SettingsView: View {
    @State private var settings = Settings.load()

    var body: some View {
        TabView {
            ShortcutsPane(settings: $settings, onChange: save)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            GlossaryPane(settings: $settings, onChange: save)
                .tabItem { Label("Glossary", systemImage: "text.book.closed") }

            ModelsPane(settings: $settings, onChange: save)
                .tabItem { Label("Models", systemImage: "cpu") }

            KeysPane(settings: settings)
                .tabItem { Label("Keys", systemImage: "key") }

            BehaviourPane(settings: $settings, onChange: save)
                .tabItem { Label("Behaviour", systemImage: "gearshape") }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 380)
    }

    /// Persists the current in-memory settings. A write failure here is surfaced to the console
    /// rather than crashing a background menu-bar app over a settings-file write; the in-memory
    /// value the user sees stays correct either way.
    private func save() {
        do {
            try settings.save()
        } catch {
            NSLog("MyDikte: failed to save settings: \(error.localizedDescription)")
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @Binding var settings: Settings
    let onChange: () -> Void

    var body: some View {
        Form {
            ShortcutRecorderRow(
                title: "Push to talk",
                isModifierOnly: true,
                chord: $settings.pushToTalkChord,
                onChange: onChange
            )
            ShortcutRecorderRow(
                title: "Start/Stop toggle",
                isModifierOnly: false,
                chord: $settings.toggleShortcut,
                onChange: onChange
            )
            ShortcutRecorderRow(
                title: "Cancel",
                isModifierOnly: false,
                chord: $settings.cancelShortcut,
                onChange: onChange
            )
            ShortcutRecorderRow(
                title: "Mode 2 prompt toggle",
                isModifierOnly: false,
                chord: $settings.promptToggleShortcut,
                onChange: onChange
            )

            Text("Push to talk is two modifiers pressed in order, and each side counts as its own key. "
                + "The other two are a modifier plus a key. Leave a row unset to keep the built-in default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
    }
}

/// Records one chord by installing a local `NSEvent` monitor while active, following the
/// interactive-capture shape in
/// `references/pindrop/Pindrop/UI/Settings/HotkeysSettingsView.swift:248-321`, trimmed to this
/// app's single `Settings.KeyChord` representation instead of Pindrop's per-slot conflict engine.
private struct ShortcutRecorderRow: View {
    let title: String
    let isModifierOnly: Bool
    @Binding var chord: Settings.KeyChord
    let onChange: () -> Void

    @State private var isRecording = false
    @State private var monitor: Any?
    /// The physical keys pressed so far, in the order they arrived. Push-to-talk is an ordered
    /// gesture, so that order is part of what is being recorded, and a chord is only committed once
    /// two different keys are down.
    @State private var pressedKeys: [ShortcutCoordinator.ModifierKey] = []

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(isRecording ? "Listening…" : ShortcutFormatter.describe(chord))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(isRecording ? .orange : .secondary)
            Button(isRecording ? "Cancel" : "Record") {
                isRecording ? stopRecording() : startRecording()
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        pressedKeys = []

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            isModifierOnly ? recordModifierChord(from: event) : recordKeyedShortcut(from: event)
        }
    }

    /// Two different physical keys, in the order they went down. The side matters here, so the key is
    /// read from the event's key code rather than from its device-independent flags, which carry none.
    private func recordModifierChord(from event: NSEvent) -> NSEvent? {
        guard event.type == .flagsChanged else {
            return event
        }
        guard
            let key = ShortcutBinding.pressedModifierKey(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags
            ),
            !pressedKeys.contains(key)
        else {
            return nil
        }

        pressedKeys.append(key)
        guard pressedKeys.count == 2 else {
            return nil
        }

        chord = ShortcutBinding.keyChord(pressedKeys)
        stopRecording()
        onChange()
        return nil
    }

    /// A key plus at least one modifier. A bare key is ignored rather than stored: registering one
    /// globally would take it away from every app in the session, so recording stays open instead.
    private func recordKeyedShortcut(from event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown else {
            return event
        }

        let keys: [ShortcutCoordinator.ModifierKey] = ShortcutBinding.modifierKeys(from: event.modifierFlags)
        guard !keys.isEmpty else {
            return nil
        }

        chord = ShortcutBinding.keyChord(keys, keyCode: event.keyCode)
        stopRecording()
        onChange()
        return nil
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
        pressedKeys = []
    }
}

private enum ShortcutFormatter {
    /// An unreadable chord reads as unset on purpose: `ShortcutBinding` does not honour one either,
    /// so the row shows what the app will actually use.
    static func describe(_ chord: Settings.KeyChord) -> String {
        guard let keys: [ShortcutCoordinator.ModifierKey] = ShortcutBinding.modifierKeys(in: chord),
            !keys.isEmpty
        else {
            return "Not set"
        }

        guard let keyCode: UInt16 = chord.keyCode else {
            return keys.map(name(for:)).joined(separator: " then ")
        }
        return "\(symbols(for: ShortcutBinding.modifierFlags(for: keys))) key \(keyCode)"
    }

    /// Carbon cannot tell the two sides of a modifier apart, so a keyed shortcut is drawn without a
    /// side while the push-to-talk chord above is drawn with one.
    private static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        return parts.joined()
    }

    private static func name(for key: ShortcutCoordinator.ModifierKey) -> String {
        switch key {
        case .leftControl: return "L⌃"
        case .rightControl: return "R⌃"
        case .leftOption: return "L⌥"
        case .rightOption: return "R⌥"
        case .leftShift: return "L⇧"
        case .rightShift: return "R⇧"
        case .leftCommand: return "L⌘"
        case .rightCommand: return "R⌘"
        }
    }
}

// MARK: - Glossary

private struct GlossaryPane: View {
    @Binding var settings: Settings
    let onChange: () -> Void

    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("One term per line. This is the exact list sent as the transcription prompt and the cleanup vocabulary block.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .onChange(of: text) { _, newValue in
                    settings.glossaryTerms = newValue
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    onChange()
                }
        }
        .padding(.top, 12)
        .onAppear {
            text = settings.glossaryTerms.joined(separator: "\n")
        }
    }
}

// MARK: - Models

private struct ModelsPane: View {
    @Binding var settings: Settings
    let onChange: () -> Void

    var body: some View {
        Form {
            Picker("Transcription provider", selection: $settings.transcriptionProvider) {
                ForEach(Settings.TranscriptionProvider.allCases, id: \.self) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            .onChange(of: settings.transcriptionProvider) { _, _ in onChange() }

            TextField("Transcription model id", text: $settings.transcriptionModelId)
                .onChange(of: settings.transcriptionModelId) { _, _ in onChange() }

            Divider()

            TextField("Cleanup model id", text: $settings.cleanupModelId)
                .onChange(of: settings.cleanupModelId) { _, _ in onChange() }

            TextField("Cleanup endpoint", text: $settings.cleanupEndpoint)
                .onChange(of: settings.cleanupEndpoint) { _, _ in onChange() }

            TextField("Rewrite endpoint", text: $settings.rewriteEndpoint)
                .onChange(of: settings.rewriteEndpoint) { _, _ in onChange() }
        }
        .padding(.top, 12)
    }
}

// MARK: - Keys

/// Both fields write straight to `KeychainStore` and never read a stored value back: the field
/// always starts empty, and a status line (not the value) reports whether an account already
/// holds a key.
private struct KeysPane: View {
    let settings: Settings

    @State private var transcriptionKey = ""
    @State private var cleanupKey = ""

    var body: some View {
        Form {
            KeyFieldRow(
                title: "Transcription API key",
                account: settings.transcriptionProvider.keychainAccount,
                value: $transcriptionKey
            )

            Divider()

            KeyFieldRow(
                title: "Cleanup API key",
                account: cleanupAccount,
                value: $cleanupKey
            )

            Text("The cleanup key is stored under the account for the endpoint on the Models pane "
                + "(currently \(cleanupAccount)). Change the endpoint and the key for the new provider "
                + "goes in here again.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
    }

    /// Derived from the pipeline's own resolver rather than restated: the account depends on the
    /// configured endpoint, and a second copy of that mapping is exactly how the pane came to write
    /// the key to an account no client read.
    private var cleanupAccount: String {
        PipelineConfiguration(settings: settings).chatKeychainAccount(for: .dictate)
    }
}

private struct KeyFieldRow: View {
    let title: String
    let account: String
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField(title, text: $value)
                Button("Save") {
                    KeychainStore.store(value, forAccount: account)
                    // Never echo the stored value back into the field.
                    value = ""
                }
                .disabled(value.isEmpty)
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch KeychainStore.read(forAccount: account) {
        case .found:
            return "A key is stored."
        case .missing:
            return "No key stored yet."
        case .unavailable:
            return "Keychain is currently unavailable."
        }
    }
}

// MARK: - Behaviour

private struct BehaviourPane: View {
    @Binding var settings: Settings
    let onChange: () -> Void

    var body: some View {
        Form {
            Toggle("Auto-insert result at the caret", isOn: $settings.autoInsert)
                .onChange(of: settings.autoInsert) { _, _ in onChange() }

            Toggle("Retain audio recordings", isOn: $settings.retainAudio)
                .onChange(of: settings.retainAudio) { _, _ in onChange() }

            Toggle("Play the start and stop cues", isOn: $settings.audioCuesEnabled)
                .onChange(of: settings.audioCuesEnabled) { _, _ in onChange() }

            Stepper(
                "History limit: \(settings.historyLimit)",
                value: $settings.historyLimit,
                in: 0...500
            )
            .onChange(of: settings.historyLimit) { _, _ in onChange() }
        }
        .padding(.top, 12)
    }
}
