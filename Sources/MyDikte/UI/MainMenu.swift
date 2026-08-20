import AppKit

/// The application menu bar, which this app went without until it turned out that going without one
/// breaks text editing.
///
/// **The bug this exists to fix.** On macOS, Command-V is not handled by the text field; it is the
/// key equivalent of the Paste item in the Edit menu, and `NSApplication` matches key equivalents
/// against `mainMenu` before anything else sees them. With `mainMenu` nil there is nothing to match,
/// so the keystroke is discarded and every field in the Settings window silently refuses to paste.
/// The user hit it on the API key field, where pasting is the only sane way to enter a 51-character
/// secret, but it applied equally to the glossary, the model ids and the endpoints.
///
/// Every item targets `nil`, which is what sends the action down the responder chain to whichever
/// field is focused. That is also why no item needs enabling logic: `NSTextView` answers
/// `validateUserInterfaceItem` for these selectors and AppKit greys out what does not apply.
///
/// A menu bar is only visible while the app is in `.regular`, which `SettingsWindowController` and
/// `WindowActivationPolicy` already switch between. So this appears with the Settings and History
/// windows and is gone the rest of the time, which is the behaviour a menu-bar app should have.
@MainActor
enum MainMenu {
    /// Builds the menu bar and installs it. Called once, at launch.
    static func install() {
        let menu = NSMenu()
        menu.addItem(applicationMenuItem())
        menu.addItem(editMenuItem())
        NSApplication.shared.mainMenu = menu
    }

    /// The leftmost menu. macOS draws its title from the bundle name rather than from what is set
    /// here, so the title is only what shows if that lookup ever fails.
    private static func applicationMenuItem() -> NSMenuItem {
        let submenu = NSMenu(title: BundleInfo.applicationName)
        // The only item here with an explicit target: the others are AppKit selectors that resolve
        // down the responder chain, and this one is this app's own.
        let settings = submenu.addItem(
            withTitle: "Settings…",
            action: #selector(AppMenuActions.openSettings(_:)),
            keyEquivalent: ","
        )
        settings.target = AppMenuActions.shared
        submenu.addItem(.separator())
        submenu.addItem(
            withTitle: "Hide \(BundleInfo.applicationName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        submenu.addItem(.separator())
        submenu.addItem(
            withTitle: "Quit \(BundleInfo.applicationName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let item = NSMenuItem()
        item.submenu = submenu
        return item
    }

    /// The menu that actually fixes the bug. Undo and Redo are included because a text field without
    /// Command-Z is broken in the same way and for the same reason.
    private static func editMenuItem() -> NSMenuItem {
        let submenu = NSMenu(title: "Edit")
        for entry in editEntries {
            let item = submenu.addItem(
                withTitle: entry.title,
                action: entry.action,
                keyEquivalent: entry.keyEquivalent
            )
            item.keyEquivalentModifierMask = entry.modifiers
        }

        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// One entry per editing command, as data so the set is reviewable and testable rather than
    /// buried in imperative menu construction.
    struct EditEntry {
        let title: String
        let action: Selector
        let keyEquivalent: String
        let modifiers: NSEvent.ModifierFlags
    }

    static let editEntries: [EditEntry] = [
        EditEntry(
            title: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z",
            modifiers: [.command]
        ),
        EditEntry(
            title: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z",
            modifiers: [.command, .shift]
        ),
        EditEntry(
            title: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x",
            modifiers: [.command]
        ),
        EditEntry(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c",
            modifiers: [.command]
        ),
        EditEntry(
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v",
            modifiers: [.command]
        ),
        EditEntry(
            title: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a",
            modifiers: [.command]
        ),
    ]
}

/// The one menu action that is this app's own rather than AppKit's. `Settings…` has no standard
/// selector to send down the responder chain, so it goes through a target this type owns.
@MainActor
final class AppMenuActions: NSObject {
    /// Set once at launch by `AppDelegate`, which is the only place that owns the window controller.
    static var onOpenSettings: (@MainActor () -> Void)?

    static let shared = AppMenuActions()

    @objc func openSettings(_ sender: Any?) {
        Self.onOpenSettings?()
    }
}
