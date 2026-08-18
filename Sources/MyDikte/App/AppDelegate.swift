import AppKit

/// Owns the status item and its menu. Every AppKit lifecycle callback lands here on the main
/// actor, per this project's concurrency convention for UI-owning types.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?

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

    /// Builds the real status item (Step 15) and its settings window, then wires the one seam
    /// that exists inside this same step: Settings. The Start/Stop, Cancel, History and
    /// Launch-at-Login seams stay on their logging no-op defaults until Steps 16 and 17 land.
    private func setUpStatusItem() {
        let windowController = SettingsWindowController()
        settingsWindowController = windowController

        let controller = StatusItemController()
        controller.onOpenSettings = { [weak windowController] in
            windowController?.show()
        }
        controller.installDebugMenuItem(DebugMenu.buildMenuItem())
        statusItemController = controller
    }
}
