import Testing

@testable import MyDikteKit

/// The work Mac's side of a remote run as a pure value, so what a shortcut press does in each state
/// is decided here and the app only performs the returned action.
@Suite("RemoteSession")
struct RemoteSessionTests {
    private static let editor = FocusTarget(
        processIdentifier: 501,
        bundleIdentifier: "com.example.editor",
        localizedName: "Editor"
    )
    private static let browser = FocusTarget(
        processIdentifier: 777,
        bundleIdentifier: "com.example.browser",
        localizedName: "Browser"
    )

    private static func connectedSession() -> RemoteSession {
        var session = RemoteSession()
        session.receive(.hello(RemoteShortcuts.default))
        return session
    }

    @Test("a new session is disconnected and the hello brings it to idle")
    func helloLeavesDisconnected() {
        var session = RemoteSession()
        #expect(session.state == .disconnected)

        session.receive(.hello(RemoteShortcuts.default))

        #expect(session.state == .idle)
    }

    @Test("any press while disconnected beeps", arguments: [RemoteHotkey.toggle, .promptToggle, .cancel])
    func pressWhileDisconnectedBeeps(key: RemoteHotkey) {
        var session = RemoteSession()

        #expect(session.press(key, frontmost: Self.editor) == .beep)
        #expect(session.target == nil)
    }

    @Test("toggle while idle sends toggle dictate and captures the frontmost target")
    func toggleFromIdleCapturesTarget() {
        var session = Self.connectedSession()

        let action: RemoteSessionAction = session.press(.toggle, frontmost: Self.editor)

        #expect(action == .send(.trigger(.toggle(.dictate)), capture: Self.editor))
        #expect(session.target == Self.editor)
    }

    @Test("the prompt toggle while idle sends toggle prompt and captures the target")
    func promptToggleFromIdleCapturesTarget() {
        var session = Self.connectedSession()

        let action: RemoteSessionAction = session.press(.promptToggle, frontmost: Self.editor)

        #expect(action == .send(.trigger(.toggle(.prompt)), capture: Self.editor))
        #expect(session.target == Self.editor)
    }

    @Test("toggle while recording sends toggle without capturing again")
    func toggleWhileRecordingKeepsTheTarget() {
        var session = Self.connectedSession()
        _ = session.press(.toggle, frontmost: Self.editor)
        session.receive(.stage(.recording))

        let action: RemoteSessionAction = session.press(.toggle, frontmost: Self.browser)

        #expect(action == .send(.trigger(.toggle(.dictate)), capture: nil))
        #expect(session.target == Self.editor)
    }

    @Test("a second toggle before the first stage arrives does not move the target")
    func secondToggleBeforeTheStageKeepsTheTarget() {
        var session = Self.connectedSession()
        _ = session.press(.toggle, frontmost: Self.editor)

        let action: RemoteSessionAction = session.press(.toggle, frontmost: Self.browser)

        #expect(action == .send(.trigger(.toggle(.dictate)), capture: nil))
        #expect(session.target == Self.editor)
    }

    @Test("cancel sends cancel and captures nothing")
    func cancelSendsCancel() {
        var session = Self.connectedSession()
        _ = session.press(.toggle, frontmost: Self.editor)
        session.receive(.stage(.recording))

        let action: RemoteSessionAction = session.press(.cancel, frontmost: Self.browser)

        #expect(action == .send(.trigger(.cancel), capture: nil))
        #expect(session.target == Self.editor)
    }

    @Test("stages move the state, and idle ends the run and releases the target")
    func stagesMoveTheState() {
        var session = Self.connectedSession()
        _ = session.press(.toggle, frontmost: Self.editor)

        session.receive(.stage(.recording))
        #expect(session.state == .recording)

        session.receive(.stage(.processing))
        #expect(session.state == .processing)
        #expect(session.target == Self.editor)

        session.receive(.stage(.idle))
        #expect(session.state == .idle)
        #expect(session.target == nil)
    }

    @Test("a result keeps the target so the paste can still read it")
    func resultKeepsTheTarget() {
        var session = Self.connectedSession()
        _ = session.press(.toggle, frontmost: Self.editor)
        session.receive(.stage(.processing))

        session.receive(.result(text: "hello"))

        #expect(session.target == Self.editor)
    }

    @Test("a failure ends the run and releases the target")
    func failureReleasesTheTarget() {
        var session = Self.connectedSession()
        _ = session.press(.toggle, frontmost: Self.editor)
        session.receive(.stage(.processing))

        session.receive(.failure(message: "no microphone"))

        #expect(session.target == nil)
    }

    @Test("the next run after idle captures the then-frontmost target")
    func nextRunCapturesAgain() {
        var session = Self.connectedSession()
        _ = session.press(.toggle, frontmost: Self.editor)
        session.receive(.stage(.idle))

        let action: RemoteSessionAction = session.press(.toggle, frontmost: Self.browser)

        #expect(action == .send(.trigger(.toggle(.dictate)), capture: Self.browser))
        #expect(session.target == Self.browser)
    }

    @Test("losing the connection drops the state and the target")
    func disconnectDropsEverything() {
        var session = Self.connectedSession()
        _ = session.press(.toggle, frontmost: Self.editor)
        session.receive(.stage(.recording))

        session.disconnected()

        #expect(session.state == .disconnected)
        #expect(session.target == nil)
        #expect(session.press(.toggle, frontmost: Self.editor) == .beep)
    }
}
