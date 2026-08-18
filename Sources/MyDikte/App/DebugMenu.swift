import AppKit

/// Registration hook for the hidden debug submenu under the status item.
///
/// Each Wave 2 area (`Audio`, `Hotkeys`, `Store`, `Output`) registers its own entry from its
/// own `App/DebugMenu+<Area>.swift` file, so no two areas need to edit this file to exercise
/// their surface by hand inside the real signed bundle.
@MainActor
enum DebugMenu {
    /// One hand-triggerable action, shown as a single menu item under "Debug".
    struct Entry {
        let title: String
        let action: () -> Void
    }

    private static var entries: [Entry] = []

    /// Areas call this once at launch to add their own debug action.
    static func register(title: String, action: @escaping () -> Void) {
        entries.append(Entry(title: title, action: action))
    }

    /// The submenu is hidden by default; a stray "Debug" item in a shipped build would confuse
    /// hands-on QA, so it only appears when explicitly asked for.
    static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["MYDIKTE_DEBUG"] != nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "MYDIKTE_DEBUG")
    }

    /// Builds the "Debug" menu item, or `nil` when debugging is disabled.
    ///
    /// The submenu populates itself when it opens rather than when it is built. That matters
    /// because the status menu is assembled once in `applicationDidFinishLaunching`, while each
    /// area registers its entry from its own `DebugMenu+<Area>.swift`: building the items eagerly
    /// would silently drop every entry registered after this call, and the order would depend on
    /// which area happened to run first.
    static func buildMenuItem() -> NSMenuItem? {
        guard isEnabled else {
            return nil
        }

        let submenu = NSMenu(title: "Debug")
        submenu.delegate = submenuDelegate

        let menuItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        menuItem.submenu = submenu
        return menuItem
    }

    /// Retained for the app's lifetime: `NSMenu.delegate` is a weak reference.
    private static let submenuDelegate = DebugSubmenuDelegate()

    /// Rebuilds `menu`'s items from whatever is registered right now.
    fileprivate static func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard !entries.isEmpty else {
            let empty = NSMenuItem(title: "No debug actions registered", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for entry in entries {
            let item = NSMenuItem(
                title: entry.title,
                action: #selector(DebugMenuActionTarget.invoke(_:)),
                keyEquivalent: ""
            )
            let target = DebugMenuActionTarget(action: entry.action)
            item.target = target
            // NSMenuItem does not retain its target; representedObject keeps it alive for as
            // long as the menu item exists.
            item.representedObject = target
            menu.addItem(item)
        }
    }
}

/// Populates the debug submenu each time it opens, so registration order never matters.
@MainActor
private final class DebugSubmenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        DebugMenu.populate(menu)
    }
}

/// Bridges a Swift closure to the Objective-C target/action pair `NSMenuItem` requires, so
/// `DebugMenu.register` callers can pass a plain closure instead of an `@objc` method.
@MainActor
private final class DebugMenuActionTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke(_ sender: Any?) {
        action()
    }
}
