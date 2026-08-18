import AppKit

/// Owns the real menu-bar status item: a state-driven icon plus the full action menu.
///
/// Start/Stop, Cancel and History have no owner yet: the pipeline lands in Step 17 and the
/// history window in Step 16, both in Wave 4. Each is wired through an injectable closure that
/// defaults to a logging no-op, so those later steps attach to this controller instead of
/// editing it, per the plan's Wave 3 to Wave 4 seam.
///
/// `references/pindrop/Pindrop/UI/StatusBarController.swift:129,166` is the status-item and
/// template-image pattern this follows.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    /// The four states this status item renders, per Step 15's description.
    enum State {
        case idle
        case recording
        case working
        case error
    }

    /// Fires when the user selects Settings. Set once, at construction, by `AppDelegate`; not a
    /// Wave 4 seam like the closures below, since the settings window exists in this same step.
    var onOpenSettings: () -> Void = {}

    /// Wave 4 seams. Each defaults to a no-op that logs, so a forgotten wiring shows up in the
    /// console rather than as a dead menu item nobody can diagnose.
    var onStart: () -> Void = { NSLog("MyDikte: Start action not wired yet") }
    var onStop: () -> Void = { NSLog("MyDikte: Stop action not wired yet") }
    var onCancel: () -> Void = { NSLog("MyDikte: Cancel action not wired yet") }
    var onOpenHistory: () -> Void = { NSLog("MyDikte: History action not wired yet") }

    /// The launch-at-login toggle has no real backing yet either: `SMAppService` registration is
    /// Step 16's Reuse Map entry, not this one's, so this menu item only reports the click.
    var onToggleLaunchAtLogin: (Bool) -> Void = { enabled in
        NSLog("MyDikte: Launch at login toggle not wired yet (requested \(enabled))")
    }

    private let permissionGate = PermissionGate()

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    private var accessibilityWarningItem: NSMenuItem?
    private var startStopItem: NSMenuItem?
    private var cancelItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?
    private var quitItem: NSMenuItem?

    private(set) var state: State = .idle {
        didSet {
            updateIcon()
            updateStartStopAndCancel()
        }
    }

    private var launchAtLoginEnabled = false {
        didSet {
            launchAtLoginItem?.state = launchAtLoginEnabled ? .on : .off
        }
    }

    override init() {
        super.init()
        buildStatusItem()
        buildMenu()
    }

    /// Called by Step 17 to reflect a pipeline stage transition. `AppDelegate` never calls this
    /// directly today; it exists so the seam is exercised from the Debug menu until Step 17 lands.
    func setState(_ newState: State) {
        state = newState
    }

    /// Inserts `item` (with a leading separator) directly before Quit, or appends it if Quit
    /// cannot be found. `AppDelegate` owns `DebugMenu`, so it passes the built item in rather than
    /// this file depending on `App/DebugMenu.swift` for a feature this step does not own.
    func installDebugMenuItem(_ item: NSMenuItem?) {
        guard let item else {
            return
        }
        guard let quitItem, let quitIndex = menu.items.firstIndex(of: quitItem) else {
            menu.addItem(.separator())
            menu.addItem(item)
            return
        }
        menu.insertItem(.separator(), at: quitIndex)
        menu.insertItem(item, at: quitIndex)
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.menu = menu
        statusItem = item
        updateIcon()
    }

    private func buildMenu() {
        menu.delegate = self

        let warning = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        warning.isEnabled = false
        warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        accessibilityWarningItem = warning

        let startStop = NSMenuItem(
            title: "Start Dictation",
            action: #selector(handleStartStop),
            keyEquivalent: ""
        )
        startStop.target = self
        startStopItem = startStop
        menu.addItem(startStop)

        let cancel = NSMenuItem(title: "Cancel", action: #selector(handleCancel), keyEquivalent: "")
        cancel.target = self
        cancelItem = cancel
        menu.addItem(cancel)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(handleOpenSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let history = NSMenuItem(title: "History…", action: #selector(handleOpenHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)

        menu.addItem(.separator())

        let launchAtLogin = NSMenuItem(
            title: "Launch at Login",
            action: #selector(handleToggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        launchAtLogin.state = .off
        launchAtLoginItem = launchAtLogin
        menu.addItem(launchAtLogin)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem = quit
        menu.addItem(quit)

        updateStartStopAndCancel()
    }

    /// Refreshes the Accessibility warning line each time the menu opens, since the grant can
    /// arrive at any point while the app runs and nothing else in this file polls for it.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let warning = accessibilityWarningItem else {
            return
        }

        let isGranted = permissionGate.refresh() == .granted
        let isPresent = menu.items.contains(warning)

        if isGranted, isPresent {
            menu.removeItem(warning)
        } else if !isGranted {
            warning.title = "⚠️ Accessibility permission needed — dictation shortcuts will not work"
            if !isPresent {
                menu.insertItem(warning, at: 0)
                menu.insertItem(.separator(), at: 1)
            }
        }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else {
            return
        }

        let symbolName: String
        switch state {
        case .idle:
            symbolName = "waveform"
        case .recording:
            symbolName = "waveform.circle.fill"
        case .working:
            symbolName = "arrow.triangle.2.circlepath.circle.fill"
        case .error:
            symbolName = "exclamationmark.triangle.fill"
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "MyDikte")
        image?.isTemplate = true
        button.image = image
    }

    private func updateStartStopAndCancel() {
        switch state {
        case .idle:
            startStopItem?.title = "Start Dictation"
            startStopItem?.isEnabled = true
            cancelItem?.isEnabled = false
        case .recording:
            startStopItem?.title = "Stop Dictation"
            startStopItem?.isEnabled = true
            cancelItem?.isEnabled = true
        case .working:
            startStopItem?.title = "Working…"
            startStopItem?.isEnabled = false
            cancelItem?.isEnabled = true
        case .error:
            startStopItem?.title = "Start Dictation"
            startStopItem?.isEnabled = true
            cancelItem?.isEnabled = false
        }
    }

    @objc private func handleStartStop() {
        if state == .recording {
            onStop()
        } else {
            onStart()
        }
    }

    @objc private func handleCancel() {
        onCancel()
    }

    @objc private func handleOpenSettings() {
        onOpenSettings()
    }

    @objc private func handleOpenHistory() {
        onOpenHistory()
    }

    @objc private func handleToggleLaunchAtLogin() {
        launchAtLoginEnabled.toggle()
        onToggleLaunchAtLogin(launchAtLoginEnabled)
    }
}
