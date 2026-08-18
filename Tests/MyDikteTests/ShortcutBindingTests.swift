import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@testable import MyDikte

/// Covers the bridge between the primitives `Settings` persists and the two mechanisms
/// `ShortcutCoordinator` registers. This is the layer that was missing: the settings file held
/// shortcut fields nothing ever read, so a recorded chord never reached the coordinator.
///
/// Everything here is pure: no tap, no Carbon registration, no window. The keyboard half stays
/// hands-on QA, per the plan's TDD convention.
@Suite("ShortcutBinding")
struct ShortcutBindingTests {
    private typealias ModifierKey = ShortcutCoordinator.ModifierKey

    // MARK: - Push to talk

    @Test("a two-modifier chord converts to the coordinator's ordered, side-specific chord")
    func pushToTalkConversionKeepsOrderAndSide() {
        let stored = ShortcutBinding.keyChord([.rightOption, .rightCommand])

        #expect(
            ShortcutBinding.pushToTalkChord(from: stored)
                == ShortcutCoordinator.Chord(first: .rightOption, second: .rightCommand)
        )
    }

    @Test("reversing the two modifiers converts to a different chord")
    func pushToTalkConversionIsOrdered() {
        let forward = ShortcutBinding.pushToTalkChord(from: ShortcutBinding.keyChord([.rightOption, .rightCommand]))
        let reversed = ShortcutBinding.pushToTalkChord(from: ShortcutBinding.keyChord([.rightCommand, .rightOption]))

        #expect(forward != reversed)
        #expect(reversed == ShortcutCoordinator.Chord(first: .rightCommand, second: .rightOption))
    }

    @Test("the two sides of one key convert to different chords")
    func pushToTalkConversionIsSideSpecific() {
        let right = ShortcutBinding.pushToTalkChord(from: ShortcutBinding.keyChord([.rightOption, .rightCommand]))
        let left = ShortcutBinding.pushToTalkChord(from: ShortcutBinding.keyChord([.leftOption, .rightCommand]))

        #expect(right != left)
        #expect(left?.first.keyCode == Int64(kVK_Option))
        #expect(right?.first.keyCode == Int64(kVK_RightOption))
    }

    @Test("an empty chord converts to nil, so the coordinator's own default applies")
    func emptyChordConvertsToNil() {
        let empty = Settings.KeyChord.unset

        #expect(ShortcutBinding.pushToTalkChord(from: empty) == nil)
        #expect(ShortcutBinding.keyedBinding(from: empty) == nil)
    }

    @Test("a chord of one key twice converts to nil, because it can never complete")
    func identicalKeysConvertToNil() {
        let stored = ShortcutBinding.keyChord([.rightOption, .rightOption])

        #expect(ShortcutBinding.pushToTalkChord(from: stored) == nil)
    }

    @Test("a chord with fewer or more than two modifiers converts to nil")
    func onlyTwoModifiersMakeAChord() {
        #expect(ShortcutBinding.pushToTalkChord(from: ShortcutBinding.keyChord([.rightOption])) == nil)
        #expect(
            ShortcutBinding.pushToTalkChord(
                from: ShortcutBinding.keyChord([.rightOption, .rightCommand, .leftShift])
            ) == nil
        )
    }

    @Test("an unrecognised modifier name converts to nil rather than to a wrong key")
    func unknownModifierNameConvertsToNil() {
        let stored = Settings.KeyChord(modifierKeys: ["rightOption", "hyperKey"])

        #expect(ShortcutBinding.pushToTalkChord(from: stored) == nil)
        #expect(ShortcutBinding.modifierKeys(in: stored) == nil)
    }

    // MARK: - Keyed shortcuts

    @Test("a modifier-plus-key chord converts to a Carbon binding with Carbon's own masks")
    func keyedConversionUsesCarbonMasks() {
        let stored = ShortcutBinding.keyChord([.leftControl, .leftOption], keyCode: UInt16(kVK_ANSI_D))

        #expect(
            ShortcutBinding.keyedBinding(from: stored)
                == CarbonHotkey.Binding(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey))
        )
    }

    @Test("both sides of a modifier collapse to the same Carbon mask, which Carbon cannot separate")
    func keyedConversionCollapsesSides() {
        let left = ShortcutBinding.keyedBinding(from: ShortcutBinding.keyChord([.leftShift], keyCode: 49))
        let right = ShortcutBinding.keyedBinding(from: ShortcutBinding.keyChord([.rightShift], keyCode: 49))

        #expect(left == right)
        #expect(left?.modifiers == UInt32(shiftKey))
    }

    @Test("a chord with no key code is not a keyed shortcut")
    func keyedConversionNeedsAKeyCode() {
        #expect(ShortcutBinding.keyedBinding(from: ShortcutBinding.keyChord([.leftControl, .leftOption])) == nil)
    }

    @Test("a bare key with no modifier converts to nil, since a global unmodified hot key is a trap")
    func keyedConversionNeedsAModifier() {
        #expect(ShortcutBinding.keyedBinding(from: Settings.KeyChord(modifierKeys: [], keyCode: 49)) == nil)
    }

    // MARK: - Flag translation

    @Test("Carbon's modifier bits are not NSEvent's, so the translation cannot be a pass-through")
    func carbonMasksDifferFromEventFlags() {
        let keys: [ModifierKey] = ShortcutBinding.modifierKeys(from: [.control, .option])
        let carbon: UInt32 = ShortcutBinding.carbonModifiers(for: keys)

        #expect(carbon == UInt32(controlKey | optionKey))
        #expect(carbon != UInt32(NSEvent.ModifierFlags([.control, .option]).rawValue))
    }

    @Test("every recordable modifier flag maps to a key and back to the same flag")
    func flagTranslationRoundTrips() {
        let flags: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let keys: [ModifierKey] = ShortcutBinding.modifierKeys(from: flags)

        #expect(keys.count == 4)
        #expect(ShortcutBinding.modifierFlags(for: keys) == flags)
        #expect(ShortcutBinding.carbonModifiers(for: keys) == UInt32(controlKey | optionKey | shiftKey | cmdKey))
    }

    @Test("flags carrying no recordable modifier translate to no keys")
    func flagTranslationIgnoresOtherFlags() {
        #expect(ShortcutBinding.modifierKeys(from: [.capsLock, .function]).isEmpty)
        #expect(ShortcutBinding.modifierFlags(for: []).isEmpty)
    }

    // MARK: - Recording a physical key

    @Test("a flags-changed press reports the exact side that was pressed")
    func pressedKeyKeepsTheSide() {
        let rightOption = NSEvent.ModifierFlags(
            rawValue: UInt(ModifierKey.rightOption.sideMask | ModifierKey.rightOption.generalMask.rawValue)
        )

        #expect(
            ShortcutBinding.pressedModifierKey(keyCode: UInt16(kVK_RightOption), modifierFlags: rightOption)
                == .rightOption
        )
        #expect(
            ShortcutBinding.pressedModifierKey(keyCode: UInt16(kVK_Option), modifierFlags: rightOption) == nil
        )
    }

    @Test("a release reports no key, so only presses are recorded")
    func releaseReportsNoKey() {
        #expect(ShortcutBinding.pressedModifierKey(keyCode: UInt16(kVK_RightOption), modifierFlags: []) == nil)
    }

    @Test("a non-modifier key code reports no key")
    func nonModifierReportsNoKey() {
        #expect(ShortcutBinding.pressedModifierKey(keyCode: UInt16(kVK_ANSI_D), modifierFlags: [.command]) == nil)
    }

    // MARK: - Configuration

    @Test("default settings leave every binding on the coordinator's own default")
    func defaultSettingsFallBackToCoordinatorDefaults() {
        let configuration = ShortcutBinding.configuration(from: .default)
        let defaults = ShortcutCoordinator.Configuration()

        #expect(configuration.chord == defaults.chord)
        #expect(configuration.toggle == defaults.toggle)
        #expect(configuration.cancel == defaults.cancel)
        #expect(configuration.promptToggle == defaults.promptToggle)
    }

    @Test("a persisted chord and toggle reach the configuration instead of the defaults")
    func persistedBindingsReachTheConfiguration() {
        var settings = Settings.default
        settings.pushToTalkChord = ShortcutBinding.keyChord([.leftControl, .rightCommand])
        settings.toggleShortcut = ShortcutBinding.keyChord([.leftControl, .leftShift], keyCode: UInt16(kVK_ANSI_J))

        let configuration = ShortcutBinding.configuration(from: settings)

        #expect(configuration.chord == ShortcutCoordinator.Chord(first: .leftControl, second: .rightCommand))
        #expect(
            configuration.toggle
                == CarbonHotkey.Binding(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | shiftKey))
        )
        #expect(configuration.cancel == ShortcutCoordinator.Configuration.Binding.defaultCancel)
    }

    @Test("an invalid persisted chord falls back rather than leaving the user with a dead shortcut")
    func invalidChordFallsBack() {
        var settings = Settings.default
        settings.pushToTalkChord = ShortcutBinding.keyChord([.leftOption, .leftOption])

        #expect(ShortcutBinding.configuration(from: settings).chord == ShortcutCoordinator.Chord.default)
    }

    @Test("an unset prompt toggle stays on the coordinator's own default")
    func promptToggleKeepsItsDefaultWhenUnset() {
        var settings = Settings.default
        settings.toggleShortcut = ShortcutBinding.keyChord([.leftControl], keyCode: UInt16(kVK_ANSI_J))

        #expect(
            ShortcutBinding.configuration(from: settings).promptToggle
                == ShortcutCoordinator.Configuration.Binding.defaultPromptToggle
        )
    }

    @Test("a persisted prompt toggle reaches the configuration instead of the default")
    func persistedPromptToggleReachesTheConfiguration() {
        var settings = Settings.default
        settings.promptToggleShortcut = ShortcutBinding.keyChord(
            [.leftControl, .leftShift],
            keyCode: UInt16(kVK_ANSI_L)
        )

        #expect(
            ShortcutBinding.configuration(from: settings).promptToggle
                == CarbonHotkey.Binding(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | shiftKey))
        )
    }
}
