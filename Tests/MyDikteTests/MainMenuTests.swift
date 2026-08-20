import AppKit
import Testing

@testable import MyDikte

/// The menu bar exists for exactly one reason: without it `NSApplication` has no key equivalent to
/// match Command-V against and every text field in the app silently refuses to paste. So these tests
/// assert the key equivalents rather than the titles, because the key equivalents are the feature.
@Suite("MainMenu", .serialized)
@MainActor
struct MainMenuTests {
    @Test("the Edit menu carries the six editing commands with their standard key equivalents")
    func editEntriesCarryStandardKeyEquivalents() {
        let byTitle: [String: MainMenu.EditEntry] = Dictionary(
            uniqueKeysWithValues: MainMenu.editEntries.map { ($0.title, $0) }
        )

        #expect(byTitle["Paste"]?.keyEquivalent == "v")
        #expect(byTitle["Paste"]?.modifiers == [.command])
        #expect(byTitle["Copy"]?.keyEquivalent == "c")
        #expect(byTitle["Cut"]?.keyEquivalent == "x")
        #expect(byTitle["Select All"]?.keyEquivalent == "a")
        #expect(byTitle["Undo"]?.keyEquivalent == "z")
        #expect(byTitle["Undo"]?.modifiers == [.command])
        // Redo shares Z with Undo and is distinguished only by Shift, so the modifier is the whole
        // difference between the two entries.
        #expect(byTitle["Redo"]?.keyEquivalent == "z")
        #expect(byTitle["Redo"]?.modifiers == [.command, .shift])
        #expect(MainMenu.editEntries.count == 6)
    }

    @Test("every editing action is a responder-chain selector, not a method on this app")
    func editActionsResolveDownTheResponderChain() {
        let paste = MainMenu.editEntries.first { $0.title == "Paste" }
        let copy = MainMenu.editEntries.first { $0.title == "Copy" }

        // `NSText` and `NSTextView` implement these, which is what makes a focused field the thing
        // that handles them. A selector this app declared itself would reach the field never.
        #expect(paste?.action == #selector(NSText.paste(_:)))
        #expect(copy?.action == #selector(NSText.copy(_:)))
        #expect(NSTextView.instancesRespond(to: paste!.action) == true)
        #expect(NSTextView.instancesRespond(to: copy!.action) == true)
    }

    @Test("installing puts an Edit submenu with a Paste item on the application")
    func installBuildsAnEditMenuWithPaste() {
        let previous: NSMenu? = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previous }

        MainMenu.install()

        let mainMenu: NSMenu? = NSApplication.shared.mainMenu
        #expect(mainMenu != nil)
        let edit: NSMenu? = mainMenu?.items.compactMap(\.submenu).first { $0.title == "Edit" }
        #expect(edit != nil)
        let pasteItem: NSMenuItem? = edit?.items.first { $0.title == "Paste" }
        #expect(pasteItem?.keyEquivalent == "v")
        #expect(pasteItem?.keyEquivalentModifierMask == [.command])
        // nil target is what sends it down the responder chain to the focused field.
        #expect(pasteItem?.target == nil)
    }

    @Test("the Settings item has an explicit target, since it is the one action AppKit does not own")
    func settingsItemTargetsThisApp() {
        let previous: NSMenu? = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previous }

        MainMenu.install()

        let submenus: [NSMenu] = NSApplication.shared.mainMenu?.items.compactMap(\.submenu) ?? []
        let settingsItem: NSMenuItem? = submenus
            .flatMap(\.items)
            .first { $0.title == "Settings…" }

        #expect(settingsItem?.keyEquivalent == ",")
        #expect(settingsItem?.target === AppMenuActions.shared)
    }

    @Test("the Settings item opens the window the status item opens")
    func settingsItemInvokesTheInstalledHandler() {
        let previous = AppMenuActions.onOpenSettings
        defer { AppMenuActions.onOpenSettings = previous }

        var opened = 0
        AppMenuActions.onOpenSettings = { opened += 1 }
        AppMenuActions.shared.openSettings(nil)

        #expect(opened == 1)
    }
}
