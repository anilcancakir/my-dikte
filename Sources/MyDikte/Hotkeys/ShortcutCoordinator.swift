import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

/// Owns the app's three global shortcuts across the two mechanisms that survive secure input.
///
/// Push-to-talk is a **two-modifier chord** read from the `CGEventTap`, because it needs key-up and
/// Carbon cannot deliver one, and because a modifier-only binding keeps working under secure input:
/// a tap loses KeyDown and KeyUp there while FlagsChanged still flows
/// (`references/Handy/src-tauri/src/secure_input.rs:1-20`). The chord's two-key shape is also what
/// pays for the audio warm-up, which is why the gesture reports four events rather than two: the
/// first modifier is the cue to warm the engine, completion is the cue to start keeping audio.
///
/// Toggle and cancel are keyed, so they go through Carbon, which needs only key-down and is not
/// affected by secure input at all.
///
/// This type deliberately knows nothing about audio: it emits events and Step 17 wires them to
/// `AudioCapture`.
///
/// Not `@MainActor`: the tap callback arrives on the listener's run-loop thread and the chord state
/// machine has to be readable from there. State is guarded with `NSLock`, and every event is
/// delivered on the main queue.
final class ShortcutCoordinator: @unchecked Sendable {
    /// The minimum time the chord must be held before a dictation starts. Neither reference has this:
    /// without it, a key brushed on the way past fires a recording.
    static let minimumHoldSeconds: TimeInterval = 0.15

    /// How long the second modifier has to arrive after the first. Comfortably past the 150-300 ms
    /// human gap between two modifier presses, and short enough that a warm-up opened by a stray
    /// press of the first modifier closes again quickly.
    static let abandonWindowSeconds: TimeInterval = 0.7

    /// A physical modifier key, identified by keycode so the two sides of the keyboard stay
    /// distinguishable: verified on this machine that a tap reports 58 for left Option and 61 for
    /// right Option (`evidence/step-08-11-api-probe.txt`).
    enum ModifierKey: String, Sendable, CaseIterable {
        case leftShift
        case rightShift
        case leftControl
        case rightControl
        case leftOption
        case rightOption
        case leftCommand
        case rightCommand

        init?(keyCode: Int64) {
            guard let match = Self.allCases.first(where: { $0.keyCode == keyCode }) else {
                return nil
            }
            self = match
        }

        var keyCode: Int64 {
            switch self {
            case .leftShift: return Int64(kVK_Shift)
            case .rightShift: return Int64(kVK_RightShift)
            case .leftControl: return Int64(kVK_Control)
            case .rightControl: return Int64(kVK_RightControl)
            case .leftOption: return Int64(kVK_Option)
            case .rightOption: return Int64(kVK_RightOption)
            case .leftCommand: return Int64(kVK_Command)
            case .rightCommand: return Int64(kVK_RightCommand)
            }
        }

        /// The side-specific bit macOS sets in the low 16 bits of the flags word. These are the
        /// `NX_DEVICE*KEYMASK` values; there is no Swift constant for them.
        var sideMask: UInt64 {
            switch self {
            case .leftControl: return 0x0000_0001
            case .leftShift: return 0x0000_0002
            case .rightShift: return 0x0000_0004
            case .leftCommand: return 0x0000_0008
            case .rightCommand: return 0x0000_0010
            case .leftOption: return 0x0000_0020
            case .rightOption: return 0x0000_0040
            case .rightControl: return 0x0000_2000
            }
        }

        /// The device-independent mask, shared by both sides of the same key.
        var generalMask: CGEventFlags {
            switch self {
            case .leftShift, .rightShift: return .maskShift
            case .leftControl, .rightControl: return .maskControl
            case .leftOption, .rightOption: return .maskAlternate
            case .leftCommand, .rightCommand: return .maskCommand
            }
        }

        /// Union of every side bit above, used to tell a flags word that carries side information
        /// from one that does not.
        private static let anySideMask: UInt64 = 0x0000_207F

        /// Whether this exact key is held, given the flags word from a `flagsChanged` event.
        ///
        /// The side bit is preferred because it is the only thing that separates a right-Option
        /// release from a left-Option one while the other side is still held. Some synthetic events
        /// carry only the device-independent mask, so that is the fallback rather than a wrong answer.
        func isDown(in flags: CGEventFlags) -> Bool {
            let raw: UInt64 = flags.rawValue
            if raw & Self.anySideMask != 0 {
                return raw & sideMask != 0
            }
            return raw & generalMask.rawValue != 0
        }
    }

    /// The ordered two-modifier push-to-talk binding.
    struct Chord: Sendable, Equatable {
        let first: ModifierKey
        let second: ModifierKey

        /// Right Option then Right Command: neither is a typing modifier on its own in this app's
        /// use, and both sides are distinguishable by keycode.
        static let `default` = Chord(first: .rightOption, second: .rightCommand)

        /// A chord of one key twice can never complete, so it is rejected at start rather than
        /// leaving the user with a dead shortcut.
        var isValid: Bool {
            first != second
        }
    }

    /// What the gesture reports. The four chord cases are the contract Step 17 wires to
    /// `warmUp()`, `beginKeeping()` and `cancelWarmUp()`.
    enum Event: Sendable, Equatable {
        /// The chord's first modifier went down: the moment to warm the audio engine.
        case firstModifierDown
        /// The chord completed and survived the minimum hold: start keeping audio.
        case chordCompleted
        /// The chord was released after a real hold: stop and transcribe.
        case chordReleased
        /// The gesture ended without becoming a dictation, so a warm-up must be cancelled. Covers
        /// the second modifier never arriving, a release inside the debounce, and a dead tap.
        case chordAbandoned
        /// The keyed toggle shortcut fired. Alternating start and stop is the consumer's decision:
        /// only the pipeline knows whether a dictation is running, since it can also end by cancel
        /// or by error.
        case toggleRequested
        /// The keyed cancel shortcut fired.
        case cancelRequested
        /// The keyed Mode 2 shortcut fired: start or stop a dictation that is rewritten into an
        /// English prompt rather than cleaned up. Added after Step 17 shipped, because the pipeline
        /// supported Mode 2 from the start (`toggleRequested(mode:)`) while nothing could trigger
        /// it: a requested feature was reachable only from the debug menu.
        case promptToggleRequested
    }

    /// The keyed shortcuts, whose ids travel through Carbon.
    enum KeyedAction: UInt32, Sendable {
        case toggle = 1
        case cancel = 2
        case promptToggle = 3
    }

    struct Configuration: Sendable {
        var chord: Chord
        var toggle: CarbonHotkey.Binding
        var cancel: CarbonHotkey.Binding
        var promptToggle: CarbonHotkey.Binding
        var minimumHoldSeconds: TimeInterval
        var abandonWindowSeconds: TimeInterval

        /// Defaults live here until Step 10's `Settings` supplies them; that step owns the persisted
        /// shortcut fields, and this step is written not to depend on a Wave 2 sibling.
        init(
            chord: Chord = .default,
            toggle: CarbonHotkey.Binding = Binding.defaultToggle,
            cancel: CarbonHotkey.Binding = Binding.defaultCancel,
            promptToggle: CarbonHotkey.Binding = Binding.defaultPromptToggle,
            minimumHoldSeconds: TimeInterval = ShortcutCoordinator.minimumHoldSeconds,
            abandonWindowSeconds: TimeInterval = ShortcutCoordinator.abandonWindowSeconds
        ) {
            self.chord = chord
            self.toggle = toggle
            self.cancel = cancel
            self.promptToggle = promptToggle
            self.minimumHoldSeconds = minimumHoldSeconds
            self.abandonWindowSeconds = abandonWindowSeconds
        }

        /// Namespace for the default keyed bindings, kept out of `CarbonHotkey` so that type stays a
        /// plain registration wrapper.
        enum Binding {
            /// Control-Option-D, unlikely to collide with an app shortcut.
            static let defaultToggle = CarbonHotkey.Binding(
                keyCode: UInt32(kVK_ANSI_D),
                modifiers: UInt32(controlKey | optionKey)
            )
            /// Control-Option-C. Escape is deliberately not used: a global Escape hot key would take
            /// the key away from every app in the session.
            static let defaultCancel = CarbonHotkey.Binding(
                keyCode: UInt32(kVK_ANSI_C),
                modifiers: UInt32(controlKey | optionKey)
            )
            /// Control-Option-P, for "prompt": Mode 2, the dictation that becomes an English prompt.
            static let defaultPromptToggle = CarbonHotkey.Binding(
                keyCode: UInt32(kVK_ANSI_P),
                modifiers: UInt32(controlKey | optionKey)
            )
        }
    }

    enum Failure: Error, LocalizedError, Equatable {
        case chordKeysIdentical

        var errorDescription: String? {
            switch self {
            case .chordKeysIdentical:
                return "The push-to-talk chord needs two different modifier keys."
            }
        }
    }

    private let configuration: Configuration
    private let onEvent: @MainActor @Sendable (Event) -> Void
    private let logger = Logger(subsystem: BundleInfo.bundleIdentifier, category: "Shortcuts")
    private let timerQueue = DispatchQueue(label: "\(BundleInfo.bundleIdentifier).shortcuts.timers")
    private let machineLock = NSLock()
    private var machine: ChordMachine
    private var listener: EventTapListener?
    private var carbon: CarbonHotkey?

    init(configuration: Configuration = Configuration(), onEvent: @escaping @MainActor @Sendable (Event) -> Void) {
        self.configuration = configuration
        self.onEvent = onEvent
        machine = ChordMachine(chord: configuration.chord)
    }

    deinit {
        stop()
    }

    /// Whether the tap is alive right now, for the menu bar and for hands-on QA.
    var isTapEnabled: Bool {
        listener?.isEnabled ?? false
    }

    /// Whether the tap was disabled by a deliberate user action, which is the one death that is not
    /// recovered automatically.
    var wasTapDisabledByUser: Bool {
        listener?.wasDisabledByUser ?? false
    }

    /// Installs both mechanisms. Call from the main thread: Carbon registers against the app's own
    /// event target.
    func start() throws {
        guard configuration.chord.isValid else {
            throw Failure.chordKeysIdentical
        }

        stop()

        // Carbon first, and deliberately so: it needs no permission, so the toggle and cancel
        // shortcuts work even when the Accessibility grant for the tap is still missing.
        let carbon = CarbonHotkey { [weak self] id in
            self?.handleKeyedHotkey(id: id)
        }
        try carbon.register(configuration.toggle, id: KeyedAction.toggle.rawValue)
        try carbon.register(configuration.cancel, id: KeyedAction.cancel.rawValue)
        try carbon.register(configuration.promptToggle, id: KeyedAction.promptToggle.rawValue)
        self.carbon = carbon

        let listener = EventTapListener(
            handler: { [weak self] keyEvent in
                self?.handleTapEvent(keyEvent) ?? .pass
            },
            onInterruption: { [weak self] in
                self?.feed(.listenerInterrupted)
            }
        )
        try listener.start()
        self.listener = listener
    }

    func stop() {
        listener?.stop()
        listener = nil
        carbon?.unregisterAll()
        carbon = nil

        machineLock.lock()
        machine = ChordMachine(chord: configuration.chord)
        machineLock.unlock()
    }

    /// Arms a deliberate stall in the next tap callback, which is how the timeout death and its
    /// inline recovery are proven by hand. Debug menu only.
    func stallNextTapCallback(by seconds: TimeInterval) {
        listener?.stallNextCallback(by: seconds)
    }

    // MARK: - Event plumbing

    private func handleTapEvent(_ keyEvent: EventTapListener.KeyEvent) -> EventTapListener.Disposition {
        // Keyed events are not this tap's business: the toggle and cancel shortcuts come through
        // Carbon, so they pass straight to the focused app.
        guard keyEvent.kind == .flagsChanged else {
            return .pass
        }

        let outcome: ChordMachine.Outcome = advance(.flagsChanged(keyCode: keyEvent.keyCode, flags: keyEvent.flags))
        apply(outcome)
        return outcome.swallow ? .swallow : .pass
    }

    private func handleKeyedHotkey(id: UInt32) {
        guard let action = KeyedAction(rawValue: id) else {
            return
        }

        switch action {
        case .toggle:
            emit([.toggleRequested])
        case .cancel:
            emit([.cancelRequested])
        case .promptToggle:
            emit([.promptToggleRequested])
        }
    }

    private func feed(_ input: ChordMachine.Input) {
        apply(advance(input))
    }

    private func advance(_ input: ChordMachine.Input) -> ChordMachine.Outcome {
        machineLock.lock()
        defer { machineLock.unlock() }
        return machine.handle(input)
    }

    private func apply(_ outcome: ChordMachine.Outcome) {
        for timer in outcome.timers {
            schedule(timer)
        }
        emit(outcome.events)
    }

    private func schedule(_ timer: ChordMachine.PendingTimer) {
        let delay: TimeInterval
        let input: ChordMachine.Input

        switch timer {
        case let .minimumHold(generation):
            delay = configuration.minimumHoldSeconds
            input = .minimumHoldElapsed(generation: generation)
        case let .abandonWindow(generation):
            delay = configuration.abandonWindowSeconds
            input = .abandonWindowElapsed(generation: generation)
        }

        timerQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.feed(input)
        }
    }

    private func emit(_ events: [Event]) {
        guard !events.isEmpty else {
            return
        }

        let handler = onEvent

        // Delivered through the main queue rather than `Task { @MainActor in }`: two tasks carry no
        // ordering guarantee between them, and `firstModifierDown` arriving after `chordCompleted`
        // would warm the audio engine after the recording it exists to cover. The log line is written
        // here too, so the tap callback does no work beyond reading the event and enqueueing it.
        DispatchQueue.main.async { [logger] in
            MainActor.assumeIsolated {
                for event in events {
                    logger.notice("shortcut event: \(event.logDescription, privacy: .public)")
                    handler(event)
                }
            }
        }
    }
}

extension ShortcutCoordinator.Event {
    /// Stable text for the log, so hands-on QA can read the gesture as a sequence.
    var logDescription: String {
        switch self {
        case .firstModifierDown: return "firstModifierDown"
        case .chordCompleted: return "chordCompleted"
        case .chordReleased: return "chordReleased"
        case .chordAbandoned: return "chordAbandoned"
        case .toggleRequested: return "toggleRequested"
        case .cancelRequested: return "cancelRequested"
        case .promptToggleRequested: return "promptToggleRequested"
        }
    }
}

extension ShortcutCoordinator {
    /// The push-to-talk gesture as a pure state machine, so the part that decides what the four
    /// events mean can be tested with synthetic input while the tap itself is verified by hand.
    ///
    /// Time is not read here: the machine asks for a timer and is told when it elapsed, which keeps
    /// the debounce decision deterministic in a test.
    struct ChordMachine {
        enum Input: Sendable {
            case flagsChanged(keyCode: Int64, flags: CGEventFlags)
            case minimumHoldElapsed(generation: UInt64)
            case abandonWindowElapsed(generation: UInt64)
            /// The tap died. Whatever is held has to be released, or a push-to-talk recording runs
            /// forever with no key left to end it.
            case listenerInterrupted
        }

        /// A timer the caller must schedule. The generation makes a timer that fires after the state
        /// moved on a no-op, without any cancellation plumbing.
        enum PendingTimer: Sendable, Equatable {
            case minimumHold(generation: UInt64)
            case abandonWindow(generation: UInt64)
        }

        struct Outcome: Sendable, Equatable {
            var events: [Event] = []
            var timers: [PendingTimer] = []
            /// Whether the event is kept from the focused app.
            var swallow: Bool = false
        }

        private enum Phase: Sendable, Equatable {
            case idle
            /// The first modifier is down and the abandon window is running.
            case firstHeld
            /// Both modifiers are down but the minimum hold has not elapsed, so nothing has started.
            case chordPending
            /// The hold was confirmed and `chordCompleted` was reported.
            case recording
            /// The gesture is over but a chord key is still held; a fresh press is required.
            case spent
        }

        private let chord: Chord
        private var phase: Phase = .idle
        private var isFirstDown = false
        private var isSecondDown = false
        /// Bumped on every phase change, which is what makes a stale timer identifiable.
        private var generation: UInt64 = 0

        init(chord: Chord) {
            self.chord = chord
        }

        mutating func handle(_ input: Input) -> Outcome {
            switch input {
            case let .flagsChanged(keyCode, flags):
                return handleFlagsChanged(keyCode: keyCode, flags: flags)
            case let .minimumHoldElapsed(generation):
                return handleMinimumHoldElapsed(generation: generation)
            case let .abandonWindowElapsed(generation):
                return handleAbandonWindowElapsed(generation: generation)
            case .listenerInterrupted:
                return handleInterruption()
            }
        }

        private mutating func handleFlagsChanged(keyCode: Int64, flags: CGEventFlags) -> Outcome {
            // Only the two configured keys are tracked. This is what keeps `firstModifierDown` off
            // every unrelated modifier press, which would otherwise open the microphone while the
            // user was typing a capital letter.
            if keyCode == chord.first.keyCode {
                isFirstDown = chord.first.isDown(in: flags)
            } else if keyCode == chord.second.keyCode {
                isSecondDown = chord.second.isDown(in: flags)
            } else {
                return Outcome()
            }

            // The second modifier belongs to our gesture whenever the first one is held, so both its
            // press and its release are swallowed there and a lone press of it is untouched. The
            // first modifier is always passed through: on the Turkish layout right Option is AltGr,
            // and deleting its `flagsChanged` would break dead-key composition.
            let swallow: Bool = keyCode == chord.second.keyCode && isFirstDown

            switch phase {
            case .idle:
                // Ordered gesture: the first modifier has to arrive on its own, because it is the
                // audio warm-up cue and the warm-up needs the gap before the second key.
                guard keyCode == chord.first.keyCode, isFirstDown, !isSecondDown else {
                    return Outcome()
                }
                phase = .firstHeld
                generation += 1
                return Outcome(events: [.firstModifierDown], timers: [.abandonWindow(generation: generation)])

            case .firstHeld:
                if !isFirstDown {
                    phase = isSecondDown ? .spent : .idle
                    generation += 1
                    return Outcome(events: [.chordAbandoned], swallow: swallow)
                }
                guard isSecondDown else {
                    return Outcome(swallow: swallow)
                }
                phase = .chordPending
                generation += 1
                return Outcome(timers: [.minimumHold(generation: generation)], swallow: swallow)

            case .chordPending:
                guard !(isFirstDown && isSecondDown) else {
                    return Outcome(swallow: swallow)
                }
                // Released inside the debounce: a brushed chord starts no dictation, and the
                // warm-up opened by `firstModifierDown` is closed by reporting it abandoned.
                phase = (isFirstDown || isSecondDown) ? .spent : .idle
                generation += 1
                return Outcome(events: [.chordAbandoned], swallow: swallow)

            case .recording:
                guard !(isFirstDown && isSecondDown) else {
                    return Outcome(swallow: swallow)
                }
                phase = (isFirstDown || isSecondDown) ? .spent : .idle
                generation += 1
                return Outcome(events: [.chordReleased], swallow: swallow)

            case .spent:
                if !isFirstDown, !isSecondDown {
                    phase = .idle
                    generation += 1
                }
                return Outcome(swallow: swallow)
            }
        }

        private mutating func handleMinimumHoldElapsed(generation: UInt64) -> Outcome {
            guard generation == self.generation, phase == .chordPending else {
                return Outcome()
            }

            phase = .recording
            self.generation += 1
            return Outcome(events: [.chordCompleted])
        }

        private mutating func handleAbandonWindowElapsed(generation: UInt64) -> Outcome {
            guard generation == self.generation, phase == .firstHeld else {
                return Outcome()
            }

            // The second modifier never arrived. The first key is still down, so the gesture stays
            // spent until it is released and pressed again.
            phase = .spent
            self.generation += 1
            return Outcome(events: [.chordAbandoned])
        }

        private mutating func handleInterruption() -> Outcome {
            let events: [Event]
            switch phase {
            case .recording:
                events = [.chordReleased]
            case .firstHeld, .chordPending:
                events = [.chordAbandoned]
            case .idle, .spent:
                events = []
            }

            phase = .idle
            isFirstDown = false
            isSecondDown = false
            generation += 1
            return Outcome(events: events)
        }
    }
}
