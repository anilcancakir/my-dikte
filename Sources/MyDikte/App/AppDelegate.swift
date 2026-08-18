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
        registerDebugEntries()
        setUpStatusItem()
    }

    /// Swift runs nothing automatically outside `main.swift`, and the toolchain rejects an
    /// Objective-C `+load` class method, so a `DebugMenu+<Area>.swift` file cannot register
    /// itself. Every area's registrar therefore needs one call from here, and this is the only
    /// place in the app that may make it: four parallel workers each adding their own
    /// `applicationDidFinishLaunching` would be four duplicate declarations.
    ///
    /// Registration runs before the status item is built, but that is not load-bearing: the
    /// Debug submenu populates in `menuNeedsUpdate(_:)`, so an entry registered later would
    /// still appear.
    private func registerDebugEntries() {
        guard DebugMenu.isEnabled else {
            return
        }
        DebugMenuAudio.register()
        DebugMenuHotkeys.register()
        DebugMenuStore.register()
        DebugMenuOutput.register()
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
