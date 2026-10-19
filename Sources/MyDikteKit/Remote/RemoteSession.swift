/// The shortcuts the work Mac app registers, as the session sees them.
package enum RemoteHotkey: Sendable, Equatable {
    case toggle
    case promptToggle
    case cancel
}

/// What the work Mac app does in answer to a press.
package enum RemoteSessionAction: Sendable, Equatable {
    /// Send `message`. `capture` is the target this press fixed for the run, `nil` when the press
    /// started no run or the run already has one.
    case send(RemoteMessage, capture: FocusTarget?)
    /// Nothing to send: there is no connection, so the press is told apart from a working one.
    case beep
}

/// The work Mac's side of a remote run, as a pure value so what a press does in each state is
/// tested here and the app only performs the returned action.
///
/// This Mac is the authority on the run: a press never changes `state`, only a received message
/// does, so the two machines cannot disagree about whether a recording is in flight.
package struct RemoteSession: Sendable, Equatable {
    package enum State: Sendable, Equatable {
        case disconnected
        case idle
        case recording
        case processing
    }

    package private(set) var state: State = .disconnected

    /// The application that was frontmost when the run was started. It is fixed there and kept until
    /// the run ends, because the text arrives a transcription round trip later and the user has
    /// usually looked elsewhere by then. Read it before `receive` of a result: the run ends on the
    /// `idle` stage that follows.
    package private(set) var target: FocusTarget?

    package init() {}

    package mutating func press(_ key: RemoteHotkey, frontmost: FocusTarget?) -> RemoteSessionAction {
        guard state != .disconnected else {
            return .beep
        }

        switch key {
        case .toggle:
            return toggle(.dictate, frontmost: frontmost)
        case .promptToggle:
            return toggle(.prompt, frontmost: frontmost)
        case .cancel:
            return .send(.trigger(.cancel), capture: nil)
        }
    }

    package mutating func receive(_ message: RemoteMessage) {
        switch message {
        case .hello:
            // A hello is the first thing a connection carries, so it is what ends `disconnected`.
            if state == .disconnected {
                state = .idle
            }
        case let .stage(stage):
            state = Self.state(for: stage)
            if stage == .idle {
                target = nil
            }
        case .failure:
            target = nil
        case .trigger, .result:
            break
        }
    }

    package mutating func disconnected() {
        state = .disconnected
        target = nil
    }

    private mutating func toggle(_ mode: RemoteMessage.Mode, frontmost: FocusTarget?) -> RemoteSessionAction {
        // A second press before the first stage arrives must not move the target: the run it
        // started is already aimed at the first application.
        guard state == .idle, target == nil else {
            return .send(.trigger(.toggle(mode)), capture: nil)
        }

        target = frontmost
        return .send(.trigger(.toggle(mode)), capture: frontmost)
    }

    private static func state(for stage: RemoteMessage.Stage) -> State {
        switch stage {
        case .recording: return .recording
        case .processing: return .processing
        case .idle: return .idle
        }
    }
}
