import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// The one place that maps the primitives `Settings` persists onto the types that actually register
/// a shortcut, in both directions.
///
/// It exists because the two ends cannot depend on each other. `Store/Settings.swift` depends on no
/// other area, so it cannot name `ShortcutCoordinator.Chord` or import Carbon; `ShortcutCoordinator`
/// owns the defaults and knows nothing about a file on disk. Without this bridge the settings file
/// carried shortcut fields nothing ever read, so every shortcut the user recorded was silently
/// ignored.
///
/// Three translations are load-bearing and none of them is a pass-through:
/// - Push-to-talk is an **ordered** pair of **side-specific** physical keys, so the stored order and
///   the stored side both matter (`ShortcutCoordinator.ModifierKey`).
/// - A keyed shortcut goes to Carbon, whose modifier bits (`controlKey`, `optionKey`, `cmdKey`,
///   `shiftKey`) are a different layout from `NSEvent.ModifierFlags`.
/// - An empty or invalid stored chord resolves to `nil` so the coordinator's own default applies.
///   Defaults are never copied here: two files holding the same default can disagree.
enum ShortcutBinding {
    typealias ModifierKey = ShortcutCoordinator.ModifierKey

    /// The modifiers a keyed shortcut can be recorded with, in the order they are stored and shown.
    ///
    /// The left-side key is the canonical spelling for a keyed shortcut: `NSEvent`'s
    /// device-independent flags carry no side, and Carbon collapses both sides of a modifier onto one
    /// mask anyway, so a keyed shortcut has no side to preserve. The push-to-talk chord does, and it
    /// is recorded from the key code instead (`pressedModifierKey(keyCode:modifierFlags:)`).
    private static let recordable: [(flag: NSEvent.ModifierFlags, key: ModifierKey)] = [
        (.control, .leftControl),
        (.option, .leftOption),
        (.shift, .leftShift),
        (.command, .leftCommand),
    ]

    // MARK: - Settings to Hotkeys

    /// The coordinator's configuration for these settings, with every unset or unusable binding left
    /// on the coordinator's own default.
    static func configuration(from settings: Settings) -> ShortcutCoordinator.Configuration {
        var configuration = ShortcutCoordinator.Configuration()

        if let chord: ShortcutCoordinator.Chord = pushToTalkChord(from: settings.pushToTalkChord) {
            configuration.chord = chord
        }
        if let toggle: CarbonHotkey.Binding = keyedBinding(from: settings.toggleShortcut) {
            configuration.toggle = toggle
        }
        if let cancel: CarbonHotkey.Binding = keyedBinding(from: settings.cancelShortcut) {
            configuration.cancel = cancel
        }
        if let promptToggle: CarbonHotkey.Binding = keyedBinding(from: settings.promptToggleShortcut) {
            configuration.promptToggle = promptToggle
        }

        return configuration
    }

    /// The push-to-talk gesture for a stored chord, or `nil` when there is none to honour.
    ///
    /// `nil` covers an unset chord, a chord that is not exactly two keys, an unrecognised key name,
    /// and one key recorded twice: `Chord.isValid` rejects the last because a chord of one key can
    /// never complete, and falling back beats handing the user a dead shortcut.
    static func pushToTalkChord(from chord: Settings.KeyChord) -> ShortcutCoordinator.Chord? {
        guard let keys: [ModifierKey] = modifierKeys(in: chord), keys.count == 2 else {
            return nil
        }

        let candidate = ShortcutCoordinator.Chord(first: keys[0], second: keys[1])
        return candidate.isValid ? candidate : nil
    }

    /// The Carbon registration for a stored keyed shortcut, or `nil` when there is none to honour.
    ///
    /// A chord with no key code is a modifier-only gesture, not a keyed one, and a key code with no
    /// modifier would register a bare key globally, taking it away from every app in the session.
    static func keyedBinding(from chord: Settings.KeyChord) -> CarbonHotkey.Binding? {
        guard let keyCode: UInt16 = chord.keyCode, let keys: [ModifierKey] = modifierKeys(in: chord), !keys.isEmpty
        else {
            return nil
        }

        return CarbonHotkey.Binding(keyCode: UInt32(keyCode), modifiers: carbonModifiers(for: keys))
    }

    /// The physical keys a stored chord names, in order, or `nil` when any name is unrecognised.
    /// A partially readable chord resolves to nothing rather than to a shortcut the user never
    /// recorded.
    static func modifierKeys(in chord: Settings.KeyChord) -> [ModifierKey]? {
        let keys: [ModifierKey] = chord.modifierKeys.compactMap(ModifierKey.init(rawValue:))
        guard keys.count == chord.modifierKeys.count else {
            return nil
        }
        return keys
    }

    // MARK: - Hotkeys to Settings

    /// A storable chord for these physical keys.
    static func keyChord(_ keys: [ModifierKey], keyCode: UInt16? = nil) -> Settings.KeyChord {
        Settings.KeyChord(modifierKeys: keys.map(\.rawValue), keyCode: keyCode)
    }

    /// The physical key a `flagsChanged` event pressed, or `nil` when the event was a release or was
    /// not about a modifier this app records.
    ///
    /// Takes the two values rather than the `NSEvent` so the side-reading rule stays testable without
    /// a synthesised event. `NSEvent.modifierFlags` and `CGEventFlags` share one bit layout, side bits
    /// in the low 16 bits included, which is what makes the coordinator's own `isDown(in:)` the right
    /// reader here: the side is exactly what the chord needs and what a device-independent mask drops.
    static func pressedModifierKey(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> ModifierKey? {
        guard let key = ModifierKey(keyCode: Int64(keyCode)) else {
            return nil
        }
        return key.isDown(in: CGEventFlags(rawValue: UInt64(modifierFlags.rawValue))) ? key : nil
    }

    // MARK: - Modifier translation

    /// The recordable modifiers held in `flags`, in this type's canonical order.
    static func modifierKeys(from flags: NSEvent.ModifierFlags) -> [ModifierKey] {
        recordable.filter { flags.contains($0.flag) }.map(\.key)
    }

    /// The device-independent `NSEvent` flags for `keys`, which is how a keyed shortcut is drawn.
    static func modifierFlags(for keys: [ModifierKey]) -> NSEvent.ModifierFlags {
        keys.reduce(into: NSEvent.ModifierFlags()) { flags, key in
            flags.insert(deviceIndependentFlag(for: key))
        }
    }

    /// Carbon's modifier mask for `keys`. Carbon has its own bit layout, so this is a translation and
    /// not a reinterpreted `NSEvent.ModifierFlags`: passing the event's raw value to
    /// `RegisterEventHotKey` registers a shortcut nobody can press.
    static func carbonModifiers(for keys: [ModifierKey]) -> UInt32 {
        UInt32(keys.reduce(into: 0) { mask, key in mask |= carbonMask(for: key) })
    }

    private static func deviceIndependentFlag(for key: ModifierKey) -> NSEvent.ModifierFlags {
        switch key {
        case .leftControl, .rightControl: return .control
        case .leftOption, .rightOption: return .option
        case .leftShift, .rightShift: return .shift
        case .leftCommand, .rightCommand: return .command
        }
    }

    private static func carbonMask(for key: ModifierKey) -> Int {
        switch key {
        case .leftControl, .rightControl: return controlKey
        case .leftOption, .rightOption: return optionKey
        case .leftShift, .rightShift: return shiftKey
        case .leftCommand, .rightCommand: return cmdKey
        }
    }
}
