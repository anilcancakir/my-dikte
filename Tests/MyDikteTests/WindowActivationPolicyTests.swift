import AppKit
import Testing

@testable import MyDikte

/// Covers `WindowActivationPolicy.shouldDemote(closing:among:)` in isolation, the pure decision
/// behind the fix for Step 17's defect: closing one of two open windows (Settings, History) was
/// unconditionally demoting the app to `.accessory` and stripping the Dock icon and menu bar out
/// from under the window still on screen.
///
/// Deliberately does not exercise `track` / `untrackAndDemoteIfNeeded` or call into
/// `NSApplication.shared.setActivationPolicy`: those are the side-effecting half, verified by
/// hand through the running app per the plan's QA convention. Bare `NSWindow` instances here are
/// used only for their `ObjectIdentifier`, never shown.
@Suite("WindowActivationPolicy")
@MainActor
struct WindowActivationPolicyTests {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    @Test("with two windows open, closing one leaves the app in .regular")
    func closingOneOfTwoStaysRegular() {
        let settings = makeWindow()
        let history = makeWindow()
        let openWindows: Set<ObjectIdentifier> = [
            ObjectIdentifier(settings),
            ObjectIdentifier(history),
        ]

        #expect(WindowActivationPolicy.shouldDemote(closing: settings, among: openWindows) == false)
    }

    @Test("closing the last open window demotes to .accessory")
    func closingLastWindowDemotes() {
        let history = makeWindow()
        let openWindows: Set<ObjectIdentifier> = [
            ObjectIdentifier(history),
        ]

        #expect(WindowActivationPolicy.shouldDemote(closing: history, among: openWindows) == true)
    }

    @Test("the closing window itself is excluded from the still-open count")
    func closingWindowIsNotCountedAsStillOpen() {
        // `windowWillClose` fires before AppKit removes the window from
        // `NSApplication.shared.windows`, so `openWindows` here still contains `settings` even
        // though it is in the process of closing. A naive `openWindows.isEmpty` check would see
        // one member and never demote; `shouldDemote` must subtract `settings` out first.
        let settings = makeWindow()
        let openWindows: Set<ObjectIdentifier> = [
            ObjectIdentifier(settings),
        ]

        #expect(WindowActivationPolicy.shouldDemote(closing: settings, among: openWindows) == true)
    }
}
