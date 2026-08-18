import AppKit

/// This step's own debug menu entry, added through Step 1's hook (`DebugMenu.register`) without
/// editing `App/DebugMenu.swift` or `App/AppDelegate.swift`, neither of which this step owns.
///
/// Posting a synthetic Cmd-V is not something a unit test can prove: the keystroke goes to whatever
/// window has focus, which in a test run is the real desktop. So the unit tests assert how the
/// sequence is constructed, and this entry drives the real thing inside the signed bundle, where the
/// Accessibility grant belongs to MyDikte rather than to the terminal that launched it.
///
/// Swift runs no code automatically for a file that is not `main.swift`, so `register()` has to be
/// called explicitly. `App/AppDelegate.swift` belongs to Step 17: until it calls
/// `DebugMenuOutput.register()`, this entry is in the binary but not in the running app's menu.
@MainActor
enum DebugMenuOutput {
    /// The QA string from the plan. Turkish characters, an apostrophe and a decimal point are exactly
    /// where a wrong pasteboard type or a character-based keystroke shows up.
    private static let probeText = "Kubernetes'e deploy ettim, ölçüm 1.09 s."

    /// Time between clicking the menu item and the insertion, for the tester to reach the caret they
    /// want the text at.
    private static let probeCountdown: Duration = .seconds(5)

    static func register() {
        DebugMenu.register(title: "Output: insert the test sentence at the caret in 5 s") {
            Task { @MainActor in
                await runProbe()
            }
        }
    }

    private static func runProbe() async {
        do {
            // The countdown is what makes this testable at all. Clicking a status-item menu makes
            // MyDikte the frontmost application, so the target has to be captured after the tester
            // has had time to click into the app and place the caret.
            try await Task.sleep(for: probeCountdown)

            guard let target = FocusTarget.current() else {
                presentFailure("No application is frontmost, so there was nothing to insert into.")
                return
            }

            try await TextInserter.insert(probeText, into: target)
        } catch {
            presentFailure(error.localizedDescription)
        }
    }

    /// An alert rather than a log line: the tester has no console attached to the bundle, and a
    /// failure the tester cannot see is indistinguishable from the silent no-op this step exists to
    /// rule out.
    private static func presentFailure(_ message: String) {
        // An accessory app's alert stays behind the target window unless the app activates first.
        NSApplication.shared.activate()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Insertion failed"
        alert.informativeText = message
        _ = alert.runModal()
    }
}
