import AppKit
import Carbon.HIToolbox
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

    /// The coordinator's own defaults, so each row can say what is in force while it holds no
    /// recording. Read from the same type the coordinator is built with, never restated here.
    private let defaults = ShortcutCoordinator.Configuration()

    var body: some View {
        Form {
            ShortcutRecorderRow(
                title: "Push to talk",
                isModifierOnly: true,
                chord: $settings.pushToTalkChord,
                fallback: ShortcutFormatter.describe(defaults.chord),
                onChange: onChange
            )
            ShortcutRecorderRow(
                title: "Start/Stop toggle",
                isModifierOnly: false,
                chord: $settings.toggleShortcut,
                fallback: ShortcutFormatter.describe(defaults.toggle),
                onChange: onChange
            )
            ShortcutRecorderRow(
                title: "Cancel",
                isModifierOnly: false,
                chord: $settings.cancelShortcut,
                fallback: ShortcutFormatter.describe(defaults.cancel),
                onChange: onChange
            )
            ShortcutRecorderRow(
                title: "Mode 2 prompt toggle",
                isModifierOnly: false,
                chord: $settings.promptToggleShortcut,
                fallback: ShortcutFormatter.describe(defaults.promptToggle),
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
    /// What the app will actually use while this row holds no recording, drawn from the coordinator's
    /// own defaults. An unrecorded row used to read "Not set" next to a shortcut that works perfectly
    /// well, which reads as a broken setting rather than as a default in force.
    let fallback: String
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
            Text(isRecording ? "Listening…" : (ShortcutFormatter.describe(chord) ?? "\(fallback) (default)"))
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
    /// A recorded chord, or `nil` when this row holds nothing the app would honour, in which case the
    /// caller draws the default instead. An unreadable chord counts as nothing on purpose:
    /// `ShortcutBinding` does not honour one either, so the row keeps showing what will actually run.
    static func describe(_ chord: Settings.KeyChord) -> String? {
        guard let keys: [ShortcutCoordinator.ModifierKey] = ShortcutBinding.modifierKeys(in: chord),
            !keys.isEmpty
        else {
            return nil
        }

        guard let keyCode: UInt16 = chord.keyCode else {
            return keys.map(name(for:)).joined(separator: " then ")
        }
        return "\(symbols(for: ShortcutBinding.modifierFlags(for: keys)))\(keyName(for: keyCode))"
    }

    /// The push-to-talk default, drawn the same way a recorded chord is.
    static func describe(_ chord: ShortcutCoordinator.Chord) -> String {
        "\(name(for: chord.first)) then \(name(for: chord.second))"
    }

    /// A keyed default. Carbon's mask is translated back rather than reinterpreted, since its bits
    /// are a different layout from `NSEvent`'s.
    static func describe(_ binding: CarbonHotkey.Binding) -> String {
        var flags = NSEvent.ModifierFlags()
        if binding.modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if binding.modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if binding.modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if binding.modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return "\(symbols(for: flags))\(keyName(for: UInt16(binding.keyCode)))"
    }

    /// The character a key code produces, so a row reads "⌃⌥D" rather than "⌃⌥ key 2". Resolved
    /// through the active keyboard layout rather than a hardcoded table, because a key code is a
    /// physical position and the letter on it depends on the layout the user actually types with.
    static func keyName(for keyCode: UInt16) -> String {
        if let named = namedKeys[keyCode] {
            return named
        }
        guard
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return "key \(keyCode)"
        }

        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status: OSStatus = data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }

        guard status == noErr, length > 0 else {
            return "key \(keyCode)"
        }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    /// Keys that produce no printable character, so the layout cannot name them.
    private static let namedKeys: [UInt16: String] = [
        UInt16(kVK_Space): "Space",
        UInt16(kVK_Return): "Return",
        UInt16(kVK_Tab): "Tab",
        UInt16(kVK_Escape): "Esc",
        UInt16(kVK_Delete): "Delete",
        UInt16(kVK_LeftArrow): "←",
        UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑",
        UInt16(kVK_DownArrow): "↓",
    ]

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
    /// Recounted from `log.jsonl` on appear and after every edit, so a term added here leaves the
    /// list immediately instead of being offered again.
    @State private var candidates: [GuardConcernLedger.Candidate] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("One term per line. This is the exact list sent as the transcription prompt and the "
                + "cleanup vocabulary block. Keep it short and keep it relevant: measured on this "
                + "machine, the same recording came back with \"LLM-friendly\" correct under six "
                + "focused terms and lost it under nineteen. Whisper reads this field as text preceding "
                + "the audio, so unrelated terms crowd out the ones that matter rather than sitting "
                + "harmlessly beside them. Add a term because you say it often, not in case you might.")
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
                    candidates = GuardConcernLedger.candidates(glossaryTerms: settings.glossaryTerms)
                }

            Divider()
            suggestions
        }
        .padding(.top, 12)
        .onAppear {
            text = settings.glossaryTerms.joined(separator: "\n")
            candidates = GuardConcernLedger.candidates(glossaryTerms: settings.glossaryTerms)
        }
    }

    /// The words the cleanup guard keeps flagging, most often first, each with a single button that
    /// adds it. Deliberately one button per term and no "add all": adding every suggestion is exactly
    /// the long glossary the caption above measures as worse, so the choice has to stay per term.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Suggested from your own dictations")
                .font(.caption.weight(.semibold))

            if candidates.isEmpty {
                Text("Nothing to suggest yet. A word appears here once the cleanup guard has had "
                    + "something to say about it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(candidates) { candidate in
                            SuggestionRow(candidate: candidate) { add(candidate.term) }
                        }
                    }
                }
                .frame(maxHeight: 96)
            }

            Text("Counted from the times the paraphrase guard flagged a word in log.jsonl, ranked by "
                + "how often. These are suggestions and nothing is ever added for you: a longer "
                + "glossary measured worse on this machine, so which of these is worth its place is "
                + "your call, one at a time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Adds one term through the text field the pane already writes through, so there is exactly one
    /// path from this pane to `Settings.save` and the editor cannot end up disagreeing with the file.
    private func add(_ term: String) {
        guard !settings.glossaryTerms.contains(term) else {
            return
        }
        text = (settings.glossaryTerms + [term]).joined(separator: "\n")
    }
}

private struct SuggestionRow: View {
    let candidate: GuardConcernLedger.Candidate
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(candidate.term)
                .font(.system(.body, design: .monospaced))
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Add", action: onAdd)
                .controlSize(.small)
        }
    }

    private var summary: String {
        let times: String = candidate.count == 1 ? "once" : "\(candidate.count) times"
        return "\(times), last on \(candidate.lastSeen.formatted(date: .abbreviated, time: .omitted))"
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

            TextField(
                "Transcription model id",
                text: $settings.transcriptionModelId,
                // Per provider, because the ids are not interchangeable: leaving this empty on
                // ElevenLabs means `scribe_v2`, and showing Groq's model there would be a lie.
                prompt: Text(settings.transcriptionProvider.defaultModelId)
            )
            .onChange(of: settings.transcriptionModelId) { _, _ in onChange() }

            Divider()

            Picker("Live preview source", selection: $settings.livePreviewProvider) {
                ForEach(Settings.LivePreviewProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .onChange(of: settings.livePreviewProvider) { _, _ in onChange() }

            Text(livePreviewSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Only meaningful while a realtime socket exists: without one there is no transcript for
            // the upload to be extra to, and the batch call happens either way.
            if settings.livePreviewProvider == .elevenLabs, settings.livePreviewEnabled {
                Toggle("Also upload for a second, more accurate reading", isOn: $settings.batchVerification)
                    .onChange(of: settings.batchVerification) { _, _ in onChange() }

                Text(batchVerificationSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            TextField(
                "Cleanup model id",
                text: $settings.cleanupModelId,
                prompt: Text(PipelineConfiguration.defaultCleanupModelId)
            )
            .onChange(of: settings.cleanupModelId) { _, _ in onChange() }

            TextField(
                "Cleanup endpoint",
                text: $settings.cleanupEndpoint,
                prompt: Text(PipelineConfiguration.groqChatEndpoint)
            )
            .onChange(of: settings.cleanupEndpoint) { _, _ in onChange() }

            TextField(
                "Rewrite endpoint",
                text: $settings.rewriteEndpoint,
                prompt: Text(PipelineConfiguration.groqChatEndpoint)
            )
            .onChange(of: settings.rewriteEndpoint) { _, _ in onChange() }

            // The stored endpoint and the endpoint used are not the same string, and showing only
            // the stored one made this pane read as misconfigured: it says api.openai.com while the
            // provider says groq, because the untouched OpenAI default is resolved to Groq rather
            // than sent to OpenAI. The pane now states what the requests will actually go to.
            Text(inUseSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 12)
    }

    /// What choosing each preview source costs, stated where the choice is made. The on-device
    /// option is free and offline; the other one bills per audio hour and streams the microphone to
    /// a hosted model, and neither of those belongs only in a docblock.
    private var livePreviewSummary: String {
        switch settings.livePreviewProvider {
        case .apple:
            return "On device, tr-TR, free, and the audio never leaves this machine. Reads Turkish "
                + "technical terms less well than the paid option."
        case .elevenLabs:
            return "Streams the microphone to ElevenLabs \(ElevenLabsLivePreview.modelId) at $0.39 per "
                + "audio hour, roughly $1.70 a month at 50 dictations a day, on top of the "
                + "transcription itself. Needs the ElevenLabs key on the Keys pane. The final text "
                + "still comes from the batch call, which measured more accurate than the realtime "
                + "model on longer recordings."
        }
    }

    /// The trade behind the extra upload, stated where the toggle is. Both directions are measured,
    /// so neither is described as the safe one.
    private var batchVerificationSummary: String {
        if settings.batchVerification {
            return "The realtime stream draws the live text and the audio is also uploaded to "
                + "scribe_v2, whose answer is the one pasted. More accurate on longer recordings, "
                + "about 700 ms slower, and it bills the same audio twice ($0.61 an audio hour)."
        }
        return "The realtime stream is the transcript, so one dictation costs one transcription "
            + "($0.39 an audio hour) and the text lands about 210 ms after you stop. This is how "
            + "ElevenLabs' own examples use it. Measured cost: the realtime model reads longer "
            + "technical speech worse than the batch one, and has dropped glossary terms it was given."
    }

    /// What the requests will actually go to, built as a plain string rather than inline in the view:
    /// the interpolated concatenation defeated the type checker.
    private var inUseSummary: String {
        let configuration = PipelineConfiguration(settings: settings)
        let transcription: String = configuration.transcriptionModelId
        let cleanup: String = configuration.cleanupModelId
        let cleanupEndpoint: String = configuration.chatEndpoint(for: .dictate)
        let rewriteEndpoint: String = configuration.chatEndpoint(for: .prompt)

        var lines: [String] = []
        lines.append("In use now: \(transcription) for transcription.")
        lines.append("\(cleanup) at \(cleanupEndpoint) for cleanup.")
        lines.append("\(rewriteEndpoint) for Mode 2.")
        lines.append(
            "An empty field means the built-in default shown in grey, and the untouched OpenAI "
                + "endpoint resolves to Groq rather than being sent to OpenAI."
        )
        return lines.joined(separator: " ")
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
    @State private var previewKey = ""

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

            // Only when the preview needs a key that no field above would have written. Choosing
            // ElevenLabs for the preview while transcribing on Groq is a real configuration, and
            // without this row the preview would silently never appear.
            if let previewAccount, previewAccount != settings.transcriptionProvider.keychainAccount {
                Divider()

                KeyFieldRow(
                    title: "Live preview API key",
                    account: previewAccount,
                    value: $previewKey
                )

                Text("The live preview is set to ElevenLabs while transcription is not, so its key "
                    + "goes in separately here, under \(previewAccount). Selecting ElevenLabs for "
                    + "transcription too makes this the same key as the one above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 12)
    }

    /// The account the preview reads, or nil when it runs on device and needs no key.
    private var previewAccount: String? {
        settings.livePreviewProvider.keychainAccount
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

            Toggle("Show the words as you speak (on device)", isOn: $settings.livePreviewEnabled)
                .onChange(of: settings.livePreviewEnabled) { _, _ in onChange() }

            Toggle("Insert the cleanup even when the guard has a concern", isOn: $settings.advisoryParaphraseGuard)
                .onChange(of: settings.advisoryParaphraseGuard) { _, _ in onChange() }

            Toggle("End a recording with Return or Space", isOn: $settings.stopOnReturnOrSpace)
                .onChange(of: settings.stopOnReturnOrSpace) { _, _ in onChange() }

            Text("Return and Space are watched only while a recording started by a shortcut is running, "
                + "and the key that stops it does not reach the app you are typing into. At every other "
                + "moment both keys behave normally, because neither is registered as a global "
                + "shortcut. Two things to know: the push-to-talk chord ignores them, since letting go "
                + "already ends it, and with a password field focused macOS hides key presses from this "
                + "app, so there the shortcut is the only way to stop. Takes effect at the next launch, "
                + "like the shortcuts themselves.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("The paraphrase guard watches for a cleanup that rewrote you instead of cleaning you "
                + "up. On, it inserts the cleanup anyway and shows what concerned it, and the word it "
                + "flagged becomes a glossary suggestion on the Glossary pane. Off, it throws that "
                + "cleanup away and inserts the raw transcript instead. On by default from measurement: "
                + "over one day of real use it turned down three correct cleanups and caught no genuine "
                + "rewrite.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("The live preview is Apple's on-device Turkish recogniser, so no audio leaves the "
                + "machine and it costs no API call. It has no punctuation and is thrown away: the "
                + "text that lands at the caret is always the transcribed and cleaned one. Off means "
                + "no recogniser is created and no authorisation is requested.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
