import AppKit

/// Owns the status item and its menu. Every AppKit lifecycle callback lands here on the main
/// actor, per this project's concurrency convention for UI-owning types.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist's LSUIElement only governs the process LaunchServices started; setting the
        // policy here too makes accessory mode hold however the binary was actually launched
        // (for example, directly from the built .build/debug path during development).
        NSApplication.shared.setActivationPolicy(.accessory)
        setUpStatusItem()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "MyDikte")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        if let debugMenuItem = DebugMenu.buildMenuItem() {
            menu.addItem(debugMenuItem)
            menu.addItem(.separator())
        }
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
    }
}
