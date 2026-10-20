import AppKit
import Carbon.HIToolbox
import MyDikteKit
import os

/// The work Mac's half of a remote dictation: registers the shortcuts this Mac's hello names, sends
/// their presses over the relay socket, shows the run's stage, and pastes the returned text into the
/// application that was in front when the run started. It records nothing itself.
@MainActor
final class RemoteAppDelegate: NSObject, NSApplicationDelegate {
    /// Fixed Carbon ids for the three shortcuts, so a rebinding replaces a registration in place.
    private static let hotkeys: [
        (id: UInt32, key: RemoteHotkey, binding: KeyPath<RemoteShortcuts, CarbonHotkey.Binding>)
    ] = [
        (1, .toggle, \.toggle),
        (2, .promptToggle, \.promptToggle),
        (3, .cancel, \.cancel),
    ]

    /// Bare Space and Return, which end a recording this Mac started. They are registered only while the
    /// session records (`syncStopKeys`): a global registration swallows the key from every app.
    private static let stopHotkeys: [(id: UInt32, binding: CarbonHotkey.Binding)] = [
        (4, CarbonHotkey.Binding(keyCode: UInt32(kVK_Space), modifiers: 0)),
        (5, CarbonHotkey.Binding(keyCode: UInt32(kVK_Return), modifiers: 0)),
    ]

    private static var shortcutsURL: URL {
        RemoteServer.directoryURL.appendingPathComponent("shortcuts.json")
    }

    private let logger = Logger(subsystem: "com.anilcan.mydikte.remote", category: "Remote")
    private let panel = RemoteIndicatorPanel()
    private var session = RemoteSession()
    private var shortcuts: RemoteShortcuts = .default
    private var stopKeysRegistered = false
    private var registrationProblem: String?
    private var serverProblem: String?
    private var statusItem: NSStatusItem?
    private var statusLine: NSMenuItem?

    private lazy var carbon: CarbonHotkey = CarbonHotkey { [weak self] id in
        Task { @MainActor in
            self?.hotkeyPressed(id: id)
        }
    }

    private lazy var server: RemoteServer = RemoteServer { [weak self] event in
        self?.handle(event)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The paste posts Cmd-V, which macOS drops silently without Accessibility. Asking at launch is
        // what puts this app in the Accessibility list at all; without the prompt it never appears.
        // The literal key, because `kAXTrustedCheckOptionPrompt` is a mutable global under Swift 6.
        let promptOption: [String: Bool] = [
            "AXTrustedCheckOptionPrompt": true,
        ]
        if !AXIsProcessTrustedWithOptions(promptOption as CFDictionary) {
            logger.notice("Accessibility not granted yet; the system prompt was shown")
        }
        installStatusItem()

        shortcuts = loadShortcuts()
        register(shortcuts)

        do {
            try server.start()
        } catch {
            logger.error("server did not start: \(error.localizedDescription, privacy: .public)")
            serverProblem = error.localizedDescription
        }
        refreshStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        carbon.unregisterAll()
        server.stop()
    }

    // MARK: - Hot keys

    private func hotkeyPressed(id: UInt32) {
        let key: RemoteHotkey
        if Self.stopHotkeys.contains(where: { $0.id == id }) {
            key = .stop
        } else if let known = Self.hotkeys.first(where: { $0.id == id })?.key {
            key = known
        } else {
            return
        }

        switch session.press(key, frontmost: FocusTarget.current()) {
        case .beep:
            NSSound.beep()
            refreshStatus()
        case .ignore:
            break
        case let .send(message, _):
            do {
                try server.send(message)
            } catch {
                logger.error("send failed: \(error.localizedDescription, privacy: .public)")
                session.disconnected()
                syncStopKeys()
                NSSound.beep()
                refreshStatus()
            }
        }
    }

    private func register(_ shortcuts: RemoteShortcuts) {
        var failures: [String] = []
        for (id, _, binding) in Self.hotkeys {
            do {
                try carbon.register(shortcuts[keyPath: binding], id: id)
            } catch {
                logger.error("hot key \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                failures.append(error.localizedDescription)
            }
        }
        registrationProblem = failures.first
    }

    /// The one place that decides whether Space and Return are registered: only while the session
    /// records. A failed registration is logged and left alone, since the toggle key still stops the run.
    private func syncStopKeys() {
        let wanted: Bool = session.state == .recording
        guard wanted != stopKeysRegistered else {
            return
        }
        stopKeysRegistered = wanted

        for (id, binding) in Self.stopHotkeys {
            guard wanted else {
                carbon.unregister(id: id)
                continue
            }

            do {
                try carbon.register(binding, id: id)
            } catch {
                logger.error("stop key \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Shortcuts file

    private func loadShortcuts() -> RemoteShortcuts {
        guard FileManager.default.fileExists(atPath: Self.shortcutsURL.path) else {
            return .default
        }

        do {
            return try JSONDecoder().decode(RemoteShortcuts.self, from: Data(contentsOf: Self.shortcutsURL))
        } catch {
            logger.error("shortcuts.json unreadable, using defaults: \(error.localizedDescription, privacy: .public)")
            return .default
        }
    }

    private func persist(_ shortcuts: RemoteShortcuts) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        do {
            try encoder.encode(shortcuts).write(to: Self.shortcutsURL, options: .atomic)
        } catch {
            logger.error("shortcuts.json not written: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Relay events

    private func handle(_ event: RemoteServer.Event) {
        switch event {
        case let .message(message):
            logger.notice("received \(Self.kind(of: message), privacy: .public)")
            receive(message)
        case .disconnected:
            session.disconnected()
            panel.hide()
        case let .listenerFailed(reason):
            serverProblem = reason
        }
        syncStopKeys()
        refreshStatus()
    }

    private func receive(_ message: RemoteMessage) {
        switch message {
        case let .hello(received):
            session.receive(message)
            persist(received)
            if received != shortcuts {
                shortcuts = received
                register(received)
            }
        case let .stage(stage):
            session.receive(message)
            panel.show(stage: stage)
        case let .result(text):
            // The session releases its target on the idle stage that follows this message.
            let target: FocusTarget? = session.target
            session.receive(message)
            paste(text, into: target)
        case let .failure(reason):
            session.receive(message)
            panel.show(message: reason)
        case .trigger:
            logger.error("ignoring a trigger message: only this Mac sends those")
        }
    }

    private func paste(_ text: String, into target: FocusTarget?) {
        Task {
            do {
                guard let target else {
                    try TextInserter.write(text, to: .general)
                    panel.show(message: "No application was in front when recording started, so the text is on the clipboard.")
                    return
                }
                try await TextInserter.insert(text, into: target)
            } catch {
                logger.error("paste failed: \(error.localizedDescription, privacy: .public)")
                panel.show(message: error.localizedDescription)
            }
        }
    }

    private static func kind(of message: RemoteMessage) -> String {
        switch message {
        case .trigger: return "trigger"
        case .hello: return "hello"
        case let .stage(stage): return "stage \(stage.rawValue)"
        case .result: return "result"
        case .failure: return "failure"
        }
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let line = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        line.isEnabled = false
        let quit = NSMenuItem(title: "Quit MyDikteRemote", action: #selector(quit), keyEquivalent: "q")
        quit.target = self

        let menu = NSMenu()
        menu.addItem(line)
        menu.addItem(.separator())
        menu.addItem(quit)
        item.menu = menu

        statusItem = item
        statusLine = line
    }

    private func refreshStatus() {
        let symbol: String
        let text: String

        if let problem = serverProblem ?? registrationProblem {
            symbol = "exclamationmark.triangle"
            text = problem
        } else {
            switch session.state {
            case .disconnected:
                symbol = "mic.slash"
                text = "Disconnected"
            case .idle:
                symbol = "mic"
                text = "Connected"
            case .recording:
                symbol = "mic.fill"
                text = "Recording"
            case .processing:
                symbol = "ellipsis.circle"
                text = "Processing"
            }
        }

        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        statusItem?.button?.toolTip = text
        statusLine?.title = text
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
