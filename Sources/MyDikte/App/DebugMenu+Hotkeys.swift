import AppKit
import os

/// This step's own debug menu entries, added through Step 1's hook (`DebugMenu.register`) without
/// editing `App/DebugMenu.swift` or `App/AppDelegate.swift`, neither of which this step owns.
///
/// The event tap cannot be unit-tested: it needs real global key presses inside the signed bundle,
/// where the Accessibility grant belongs to MyDikte rather than to the terminal that launched it.
/// These entries are the only way to exercise `ShortcutCoordinator` by hand, since nothing else in
/// the bundle creates one until Step 17.
///
/// Swift runs no code automatically for a file that is not `main.swift`, so `register()` has to be
/// called explicitly. `App/AppDelegate.swift` belongs to Step 17: until it calls
/// `DebugMenuHotkeys.register()`, these entries are in the binary but not in the running app's menu.
@MainActor
enum DebugMenuHotkeys {
    static func register() {
        DebugMenu.register(title: "Hotkeys: start and log every event") {
            HotkeysDebugController.shared.start()
        }
        DebugMenu.register(title: "Hotkeys: stop") {
            HotkeysDebugController.shared.stop()
        }
        DebugMenu.register(title: "Hotkeys: log permission and tap state") {
            HotkeysDebugController.shared.logState()
        }
        DebugMenu.register(title: "Hotkeys: stall the next tap callback (kills the tap)") {
            HotkeysDebugController.shared.stallTap()
        }
    }
}

/// Drives a real `ShortcutCoordinator` from the debug menu and writes every event it emits to the
/// unified log, which is where hands-on QA reads the gesture back:
/// `log stream --predicate 'subsystem == "com.anilcan.mydikte"' --style compact`.
@MainActor
private final class HotkeysDebugController {
    static let shared = HotkeysDebugController()

    private let logger = Logger(subsystem: BundleInfo.bundleIdentifier, category: "HotkeysDebug")
    private let permissions = PermissionGate()
    private var coordinator: ShortcutCoordinator?
    private var eventCount = 0
    /// Alternated here rather than inside the coordinator: only the pipeline knows whether a
    /// dictation is running, so the toggle reports a request and its consumer decides start or stop.
    private var isToggledOn = false

    func start() {
        guard coordinator == nil else {
            logger.notice("already listening")
            logState()
            return
        }

        // Watching before prompting, so a grant given in System Settings while this runs starts the
        // coordinator without a relaunch.
        permissions.startMonitoring { [weak self] state in
            guard let self else {
                return
            }
            logger.notice("accessibility became \(String(describing: state), privacy: .public)")
            if state == .granted {
                startCoordinator()
            }
        }

        switch permissions.requestAccessibility() {
        case .granted:
            startCoordinator()
        case .notGranted:
            logger.notice("accessibility not granted yet; the coordinator starts as soon as it is")
        }
    }

    func stop() {
        permissions.stopMonitoring()
        coordinator?.stop()
        coordinator = nil
        logger.notice("stopped listening after \(self.eventCount, privacy: .public) events")
    }

    func logState() {
        let accessibility: String = String(describing: permissions.refresh())
        let secureInput: Bool = permissions.isSecureInputEnabled
        let tapEnabled: Bool = coordinator?.isTapEnabled ?? false
        let userDisabled: Bool = coordinator?.wasTapDisabledByUser ?? false

        logger.notice(
            """
            state: accessibility=\(accessibility, privacy: .public) \
            secureInput=\(secureInput, privacy: .public) \
            tapEnabled=\(tapEnabled, privacy: .public) \
            tapDisabledByUser=\(userDisabled, privacy: .public) \
            events=\(self.eventCount, privacy: .public)
            """
        )

        if secureInput {
            // Explaining rather than looking broken is the point of the check: the chord is
            // modifier-only precisely so it survives this state.
            logger.notice("secure input is on: keyed shortcuts are blocked, the push-to-talk chord still works")
        }
    }

    func stallTap() {
        guard let coordinator else {
            logger.notice("not listening; nothing to stall")
            return
        }

        // Two seconds is well past what the window server tolerates, so the next key event kills the
        // tap with `tapDisabledByTimeout` and the inline recovery has to bring it back.
        coordinator.stallNextTapCallback(by: 2.0)
        logger.notice("next tap callback will stall for 2s; press the chord, then press it again")
    }

    private func startCoordinator() {
        guard coordinator == nil else {
            return
        }

        let coordinator = ShortcutCoordinator { [weak self] event in
            self?.handle(event)
        }

        do {
            try coordinator.start()
        } catch {
            logger.error("could not start shortcuts: \(error.localizedDescription, privacy: .public)")
            return
        }

        self.coordinator = coordinator
        logger.notice("listening; tapEnabled=\(coordinator.isTapEnabled, privacy: .public)")
    }

    private func handle(_ event: ShortcutCoordinator.Event) {
        eventCount += 1

        switch event {
        case .toggleRequested:
            isToggledOn.toggle()
            logger.notice(
                "event \(self.eventCount, privacy: .public): toggleRequested -> \(self.isToggledOn ? "start" : "stop", privacy: .public)"
            )
        case .cancelRequested:
            isToggledOn = false
            logger.notice("event \(self.eventCount, privacy: .public): cancelRequested")
        default:
            logger.notice("event \(self.eventCount, privacy: .public): \(event.logDescription, privacy: .public)")
        }
    }
}
