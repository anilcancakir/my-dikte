import AppKit
import SwiftUI

/// Hosts the settings UI in a plain `NSWindowController`, opened with `makeKeyAndOrderFront`
/// rather than through SwiftUI's `Settings` scene.
///
/// This is not a stylistic choice: SwiftUI's dedicated settings-scene APIs work on macOS 15 and
/// are documented broken on macOS 26, and the only published workaround is a hidden window scene
/// plus an activation-policy flip, which is exactly the complexity this route avoids.
/// `references/pindrop/Pindrop/UI/Settings/SettingsWindowController.swift:113,166` is the
/// `NSWindowController` plus `makeKeyAndOrderFront` pattern this follows.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private enum Layout {
        static let contentSize = NSSize(width: 560, height: 440)
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Layout.contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MyDikte Settings"
        // Retained by this controller for the app's lifetime; closing hides the window rather
        // than destroying it, so reopening does not rebuild the hosted SwiftUI state each time.
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView())

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Opens the window and gives it focus.
    ///
    /// The activation-policy flip to `.regular` happens first: an `.accessory` app cannot become
    /// key, and a menu-bar app with no Dock icon has no other way for its settings window to
    /// receive keyboard focus. `references/VoiceInk/VoiceInk/WindowManager.swift:26-42` is the
    /// pattern this follows. `WindowActivationPolicy.track` registers this window so that closing
    /// the History window while this one is still open does not demote the app out from under it.
    func show() {
        guard let window else {
            return
        }
        WindowActivationPolicy.track(window)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Defers the `.accessory` demotion to `WindowActivationPolicy`, which only flips back once
    /// no other window still requires `.regular`.
    func windowWillClose(_ notification: Notification) {
        guard let window else {
            return
        }
        WindowActivationPolicy.untrackAndDemoteIfNeeded(window)
    }
}
