import CoreGraphics
import Foundation
import Testing

@testable import MyDikte

/// The parts of the hotkey layer that can be tested without a real key press: the chord's
/// keycode-and-flags reading, and the state machine that turns synthetic `flagsChanged` input into
/// the four push-to-talk events. The tap itself, the Carbon registration and the permission gate
/// are verified by hands-on QA inside the signed bundle, per this step's plan entry.
@Suite("ShortcutCoordinator")
struct ShortcutCoordinatorTests {
    private typealias ModifierKey = ShortcutCoordinator.ModifierKey
    private typealias Machine = ShortcutCoordinator.ChordMachine

    /// Builds a flags word the way real hardware does: the side-specific bit plus the
    /// device-independent mask for every key currently held.
    private static func flags(holding keys: ModifierKey...) -> CGEventFlags {
        var raw: UInt64 = 0
        for key in keys {
            raw |= key.sideMask | key.generalMask.rawValue
        }
        return CGEventFlags(rawValue: raw)
    }

    private static func machine() -> Machine {
        Machine(chord: .default)
    }

    private static var first: ModifierKey { ShortcutCoordinator.Chord.default.first }
    private static var second: ModifierKey { ShortcutCoordinator.Chord.default.second }

    // MARK: - Chord reading

    @Test("the two Option keys are distinguished by keycode, 58 against 61")
    func optionKeysAreDistinguishedByKeyCode() {
        #expect(ModifierKey.leftOption.keyCode == 58)
        #expect(ModifierKey.rightOption.keyCode == 61)
        #expect(ModifierKey.rightCommand.keyCode == 54)
        #expect(ModifierKey(keyCode: 61) == .rightOption)
        #expect(ModifierKey(keyCode: 58) == .leftOption)
        #expect(ModifierKey(keyCode: 0) == nil)
    }

    @Test("a held left Option does not read as a held right Option")
    func sideSpecificBitSeparatesTheTwoSides() {
        let leftOnly: CGEventFlags = Self.flags(holding: .leftOption)

        #expect(ModifierKey.leftOption.isDown(in: leftOnly))
        // Both sides share `maskAlternate`, so a device-independent read would report the right
        // key as held here and never see it released.
        #expect(!ModifierKey.rightOption.isDown(in: leftOnly))
    }

    @Test("flags carrying no side bit fall back to the device-independent mask")
    func deviceIndependentFallbackIsUsedWhenNoSideBitIsPresent() {
        let synthetic = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue)

        #expect(ModifierKey.rightOption.isDown(in: synthetic))
        #expect(!ModifierKey.rightCommand.isDown(in: synthetic))
    }

    @Test("the default chord is two distinct keys, and a doubled chord is invalid")
    func chordValidityRejectsADoubledKey() {
        #expect(ShortcutCoordinator.Chord.default.isValid)
        #expect(!ShortcutCoordinator.Chord(first: .rightOption, second: .rightOption).isValid)
    }

    @Test("the minimum hold is a named 150 ms constant")
    func minimumHoldConstantIsNamed() {
        #expect(ShortcutCoordinator.minimumHoldSeconds == 0.15)
        #expect(ShortcutCoordinator.abandonWindowSeconds > ShortcutCoordinator.minimumHoldSeconds)
    }

    // MARK: - The full gesture

    @Test("a held chord emits firstModifierDown then chordCompleted then chordReleased")
    func fullGestureEmitsAllThreeEvents() {
        var machine = Self.machine()

        let firstDown = machine.handle(.flagsChanged(keyCode: Self.first.keyCode, flags: Self.flags(holding: .rightOption)))
        #expect(firstDown.events == [.firstModifierDown])
        // The first modifier is passed through: on the Turkish layout right Option is AltGr, so
        // swallowing it would break dead-key composition.
        #expect(!firstDown.swallow)
        #expect(firstDown.timers.count == 1)

        let chordDown = machine.handle(
            .flagsChanged(keyCode: Self.second.keyCode, flags: Self.flags(holding: .rightOption, .rightCommand))
        )
        // Nothing starts yet: the debounce decides whether this becomes a dictation.
        #expect(chordDown.events.isEmpty)
        #expect(chordDown.swallow)

        guard case let .minimumHold(generation)? = chordDown.timers.first else {
            Issue.record("completing the chord must arm the minimum-hold timer")
            return
        }

        let held = machine.handle(.minimumHoldElapsed(generation: generation))
        #expect(held.events == [.chordCompleted])

        let released = machine.handle(
            .flagsChanged(keyCode: Self.second.keyCode, flags: Self.flags(holding: .rightOption))
        )
        #expect(released.events == [.chordReleased])
    }

    @Test("a fresh press of the first modifier re-arms the gesture after a completed one")
    func gestureCanBeRepeated() {
        var machine = Self.machine()
        Self.driveCompletedChord(&machine)
        _ = machine.handle(.flagsChanged(keyCode: Self.second.keyCode, flags: Self.flags(holding: .rightOption)))
        _ = machine.handle(.flagsChanged(keyCode: Self.first.keyCode, flags: Self.flags()))

        let again = machine.handle(
            .flagsChanged(keyCode: Self.first.keyCode, flags: Self.flags(holding: .rightOption))
        )
        #expect(again.events == [.firstModifierDown])
    }

    // MARK: - The debounce

    @Test("a chord released before the minimum hold starts nothing")
    func brushedChordStartsNothing() {
        var machine = Self.machine()
        _ = machine.handle(.flagsChanged(keyCode: Self.first.keyCode, flags: Self.flags(holding: .rightOption)))
        let chordDown = machine.handle(
            .flagsChanged(keyCode: Self.second.keyCode, flags: Self.flags(holding: .rightOption, .rightCommand))
        )
        guard case let .minimumHold(generation)? = chordDown.timers.first else {
            Issue.record("completing the chord must arm the minimum-hold timer")
            return
        }

        // Both keys go up well inside the 150 ms window.
        let released = machine.handle(.flagsChanged(keyCode: Self.second.keyCode, flags: Self.flags()))
        // Abandoned rather than silent: the warm-up opened on `firstModifierDown` and something
        // has to close it again.
        #expect(released.events == [.chordAbandoned])

        let stale = machine.handle(.minimumHoldElapsed(generation: generation))
        #expect(stale.events.isEmpty)
    }

    // MARK: - Abandonment

    @Test("the first modifier alone, pressed and released, emits firstModifierDown then chordAbandoned")
    func firstModifierAloneIsAbandoned() {
        var machine = Self.machine()

        let down = machine.handle(
            .flagsChanged(keyCode: Self.first.keyCode, flags: Self.flags(holding: .rightOption))
        )
        #expect(down.events == [.firstModifierDown])

        let up = machine.handle(.flagsChanged(keyCode: Self.first.keyCode, flags: Self.flags()))
        #expect(up.events == [.chordAbandoned])
    }

    @Test("the second modifier arriving after the abandon window does not complete the chord")
    func abandonWindowClosesTheGesture() {
        var machine = Self.machine()
        let down = machine.handle(
            .flagsChanged(keyCode: Self.first.keyCode, flags: Self.flags(holding: .rightOption))
        )
        guard case let .abandonWindow(generation)? = down.timers.first else {
            Issue.record("the first modifier must arm the abandon-window timer")
            return
        }

        let expired = machine.handle(.abandonWindowElapsed(generation: generation))
        #expect(expired.events == [.chordAbandoned])

        let late = machine.handle(
            .flagsChanged(keyCode: Self.second.keyCode, flags: Self.flags(holding: .rightOption, .rightCommand))
        )
        #expect(late.events.isEmpty)
        #expect(late.timers.isEmpty)
    }

    @Test("an unrelated modifier never emits firstModifierDown")
    func unrelatedModifiersAreIgnored() {
        var machine = Self.machine()

        for key in [ModifierKey.leftOption, .leftCommand, .leftShift, .rightShift, .leftControl] {
            let outcome = machine.handle(.flagsChanged(keyCode: key.keyCode, flags: Self.flags(holding: key)))
            #expect(outcome.events.isEmpty)
            #expect(!outcome.swallow)
        }
    }

    @Test("the second modifier pressed on its own does nothing")
    func secondModifierAloneDoesNothing() {
        var machine = Self.machine()

        let down = machine.handle(
            .flagsChanged(keyCode: Self.second.keyCode, flags: Self.flags(holding: .rightCommand))
        )
        #expect(down.events.isEmpty)
        #expect(!down.swallow)

        // The gesture is ordered, so a chord built the other way round stays inert.
        let both = machine.handle(
            .flagsChanged(keyCode: Self.first.keyCode, flags: Self.flags(holding: .rightOption, .rightCommand))
        )
        #expect(both.events.isEmpty)
    }

    // MARK: - Tap death

    @Test("a dead tap releases a recording chord so a dictation cannot hang")
    func interruptionReleasesARecordingChord() {
        var machine = Self.machine()
        Self.driveCompletedChord(&machine)

        let interrupted = machine.handle(.listenerInterrupted)
        #expect(interrupted.events == [.chordReleased])
    }

    @Test("a dead tap abandons a chord that had not started recording yet")
    func interruptionAbandonsAnUnconfirmedChord() {
        var machine = Self.machine()
        _ = machine.handle(.flagsChanged(keyCode: Self.first.keyCode, flags: Self.flags(holding: .rightOption)))

        let interrupted = machine.handle(.listenerInterrupted)
        #expect(interrupted.events == [.chordAbandoned])
    }

    @Test("a dead tap with nothing held emits nothing")
    func interruptionWithNothingHeldIsSilent() {
        var machine = Self.machine()

        #expect(machine.handle(.listenerInterrupted).events.isEmpty)
    }

    /// Drives the machine to the recording phase: first modifier, second modifier, hold confirmed.
    private static func driveCompletedChord(_ machine: inout Machine) {
        _ = machine.handle(.flagsChanged(keyCode: first.keyCode, flags: flags(holding: .rightOption)))
        let chordDown = machine.handle(
            .flagsChanged(keyCode: second.keyCode, flags: flags(holding: .rightOption, .rightCommand))
        )
        guard case let .minimumHold(generation)? = chordDown.timers.first else {
            Issue.record("completing the chord must arm the minimum-hold timer")
            return
        }
        _ = machine.handle(.minimumHoldElapsed(generation: generation))
    }
}
