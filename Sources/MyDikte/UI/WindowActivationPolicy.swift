import AppKit

/// Owns the single decision of when the app demotes from `.regular` back to `.accessory`.
///
/// Two window controllers, `SettingsWindowController` and `HistoryWindowController`, each flip
/// the app to `.regular` on `show()` because an `.accessory` app cannot become key, and each used
/// to flip back to `.accessory` unconditionally in `windowWillClose`. With both windows open,
/// closing either one demoted the app while the other was still on screen, stripping its Dock
/// icon and menu bar out from under it. This type tracks every window currently open that
/// requires `.regular` and demotes only once none of them remain, so the app's baseline
/// (`.accessory`, set at `App/main.swift` and `App/AppDelegate.swift`) is restored only when it
/// is actually safe to.
@MainActor
enum WindowActivationPolicy {
    /// Windows currently open that require `.regular` while visible. Tracked by identity rather
    /// than by holding the windows themselves, since this type does not own their lifetime.
    private static var openWindows: Set<ObjectIdentifier> = []

    /// Call from a controller's `show()`, once `window` is the one being made key, to register it
    /// as requiring `.regular` for as long as it stays open.
    static func track(_ window: NSWindow) {
        openWindows.insert(ObjectIdentifier(window))
    }

    /// Call from `window`'s `windowWillClose`. Demotes to `.accessory` only if `window` was the
    /// last tracked window still open.
    static func untrackAndDemoteIfNeeded(_ window: NSWindow) {
        let demote = shouldDemote(closing: window, among: openWindows)
        openWindows.remove(ObjectIdentifier(window))

        guard demote else {
            return
        }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    /// The pure decision: given the full set of windows tracked as open just before `window`
    /// closes (including `window` itself), should the app demote once it closes?
    ///
    /// `windowWillClose` fires before AppKit removes the window from
    /// `NSApplication.shared.windows`, so `window` is still present in `openWindows` at the point
    /// this runs. It has to be subtracted out explicitly here rather than assumed already gone,
    /// or a single open window closing would never demote the app at all.
    static func shouldDemote(closing window: NSWindow, among openWindows: Set<ObjectIdentifier>) -> Bool {
        openWindows.subtracting([ObjectIdentifier(window)]).isEmpty
    }
}
