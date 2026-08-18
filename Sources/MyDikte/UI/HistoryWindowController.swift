import AppKit
import SwiftUI

/// Hosts `HistoryView` in a plain `NSWindowController`, the same `NSHostingView` plus
/// activation-policy-flip route `SettingsWindowController` (Step 15) uses: an `.accessory` app
/// cannot become key, and this window needs keyboard focus for copy and delete.
/// `references/pindrop/Pindrop/UI/Settings/SettingsWindowController.swift:113,166` is the
/// `NSWindowController` plus `makeKeyAndOrderFront` pattern this follows, and
/// `references/VoiceInk/VoiceInk/WindowManager.swift:26-42` is the activation-policy flip.
///
/// Unlike `SettingsWindowController`, `show()` rebuilds `HistoryView` on every call rather than
/// reusing the view built at `init`: the underlying `log.jsonl` changes from outside this window
/// while the app runs, and a window kept alive with `isReleasedWhenClosed = false` has no other
/// hook to notice that, since `HistoryView` only reloads on its own `onAppear`.
@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private enum Layout {
        static let contentSize = NSSize(width: 720, height: 480)
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Layout.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MyDikte History"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: HistoryView())

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Opens the window with a freshly loaded list and gives it focus.
    func show() {
        window?.contentView = NSHostingView(rootView: HistoryView())
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Flips back to `.accessory` so the Dock icon does not linger once the History window
    /// closes, matching `SettingsWindowController`'s reverse of the same flip.
    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
