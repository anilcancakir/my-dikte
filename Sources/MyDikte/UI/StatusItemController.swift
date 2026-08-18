import AppKit
import ServiceManagement

/// Owns the real menu-bar status item: a state-driven icon plus the full action menu.
///
/// Start/Stop and Cancel have no owner yet: the pipeline lands in Step 17, still in Wave 4, and
/// stays on its injectable logging no-op until then. History and Launch at Login are wired in
/// this step, entirely inside this file, since Step 17 owns `App/AppDelegate.swift` this wave and
/// this controller's own closures are the seam Step 16 was told to use instead.
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

    /// Wired to `historyWindowController.show()` at the end of `init`, below. Kept as a closure
    /// rather than a direct call from `handleOpenHistory` so this stays consistent with the other
    /// Wave 4 seams above, even though this one's real implementation lives in this same file.
    var onOpenHistory: () -> Void = { NSLog("MyDikte: History action not wired yet") }

    /// Wired to `setLaunchAtLogin(enabled:)` at the end of `init`, below.
    var onToggleLaunchAtLogin: (Bool) -> Void = { enabled in
        NSLog("MyDikte: Launch at login toggle not wired yet (requested \(enabled))")
    }

    private let permissionGate = PermissionGate()
    private lazy var historyWindowController = HistoryWindowController()

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

    override init() {
        super.init()
        buildStatusItem()
        buildMenu()
        wireHistoryAndLaunchAtLogin()
    }

    /// Assigns real implementations to the two Wave 4 seams this step owns. Done here, after
    /// `buildMenu()`, rather than at property declaration, since both closures capture `self`.
    private func wireHistoryAndLaunchAtLogin() {
        onOpenHistory = { [weak self] in
            self?.historyWindowController.show()
        }
        onToggleLaunchAtLogin = { [weak self] enabled in
            self?.setLaunchAtLogin(enabled: enabled)
        }
        refreshLaunchAtLoginState()
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

    /// Refreshes the Accessibility warning line and the Launch at Login checkmark each time the
    /// menu opens: both can change from outside this app (a grant in System Settings, a login
    /// item toggled from the same place) and nothing else in this file polls for either.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshLaunchAtLoginState()

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
        let requestedEnabled = launchAtLoginItem?.state != .on
        onToggleLaunchAtLogin(requestedEnabled)
    }

    // MARK: - Launch at Login

    /// The result of one read or one register/unregister call, carried back across the actor hop
    /// in `performLaunchAtLoginToggle` and `readLaunchAtLoginStatus` below.
    private struct LaunchAtLoginResult: Sendable {
        let isEnabled: Bool
        let failureMessage: String?
    }

    /// Re-reads `SMAppService.mainApp.status` and updates the checkmark, without registering or
    /// unregistering anything. Called at construction and on every menu open.
    private func refreshLaunchAtLoginState() {
        Task {
            let isEnabled = await Self.readLaunchAtLoginStatus()
            launchAtLoginItem?.state = isEnabled ? .on : .off
        }
    }

    /// Registers or unregisters via `LaunchAtLogin`, off the main actor since `SMAppService` calls
    /// can block, per `references/VoiceInk/VoiceInk/Services/LaunchAtLoginManager.swift:92-122`.
    /// A failure is surfaced through an alert rather than swallowed; the checkmark always ends up
    /// reflecting the real post-attempt status, not the requested one.
    private func setLaunchAtLogin(enabled: Bool) {
        Task {
            let result = await Self.performLaunchAtLoginToggle(enabled: enabled)
            launchAtLoginItem?.state = result.isEnabled ? .on : .off
            if let message = result.failureMessage {
                presentLaunchAtLoginFailure(message)
            }
        }
    }

    private nonisolated static func readLaunchAtLoginStatus() async -> Bool {
        await Task.detached(priority: .utility) {
            LaunchAtLogin.status == .enabled
        }.value
    }

    private nonisolated static func performLaunchAtLoginToggle(enabled: Bool) async -> LaunchAtLoginResult {
        await Task.detached(priority: .utility) {
            do {
                if enabled {
                    try LaunchAtLogin.register()
                } else {
                    try LaunchAtLogin.unregister()
                }
                return LaunchAtLoginResult(isEnabled: LaunchAtLogin.status == .enabled, failureMessage: nil)
            } catch {
                return LaunchAtLoginResult(
                    isEnabled: LaunchAtLogin.status == .enabled,
                    failureMessage: error.localizedDescription
                )
            }
        }.value
    }

    /// An accessory app's alert stays behind the target window unless the app activates first,
    /// matching `App/DebugMenu+Output.swift`'s `presentFailure`.
    private func presentLaunchAtLoginFailure(_ message: String) {
        NSApplication.shared.activate()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Launch at Login"
        alert.informativeText = message
        _ = alert.runModal()
    }
}
