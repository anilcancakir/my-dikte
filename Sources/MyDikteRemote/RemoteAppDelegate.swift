import AppKit
import MyDikteKit
import os

@MainActor
final class RemoteAppDelegate: NSObject, NSApplicationDelegate {
    private enum PasteFailure: Error, LocalizedError {
        case noTarget

        var errorDescription: String? {
            "No application was in front when recording started, so nothing was pasted. The text is on the clipboard."
        }
    }

    /// Fixed Carbon ids for the three shortcuts, so a rebinding replaces a registration in place.
    private static let hotkeys: [(id: UInt32, key: RemoteHotkey)] = [
        (1, .toggle),
        (2, .promptToggle),
        (3, .cancel),
    ]

    private static var shortcutsURL: URL {
        RemoteServer.directoryURL.appendingPathComponent("shortcuts.json")
    }

    private let logger = Logger(subsystem: "com.anilcan.mydikte.remote", category: "Remote")
    private let panel = RemoteIndicatorPanel()
    private var session = RemoteSession()
    private var shortcuts: RemoteShortcuts = .default
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
        let promptOption: [String: Bool] = ["AXTrustedCheckOptionPrompt": true]
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
        guard let key = Self.hotkeys.first(where: { $0.id == id })?.key else {
            return
        }

        switch session.press(key, frontmost: FocusTarget.current()) {
        case .beep:
            NSSound.beep()
            refreshStatus()
        case let .send(message, _):
            do {
                try server.send(message)
            } catch {
                logger.error("send failed: \(error.localizedDescription, privacy: .public)")
                session.disconnected()
                NSSound.beep()
                refreshStatus()
            }
        }
    }

    private func register(_ shortcuts: RemoteShortcuts) {
        var failures: [String] = []
        for (id, key) in Self.hotkeys {
            do {
                try carbon.register(Self.binding(for: key, in: shortcuts), id: id)
            } catch {
                logger.error("hot key \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                failures.append(error.localizedDescription)
            }
        }
        registrationProblem = failures.first
    }

    private static func binding(for key: RemoteHotkey, in shortcuts: RemoteShortcuts) -> CarbonHotkey.Binding {
        switch key {
        case .toggle: return shortcuts.toggle
        case .promptToggle: return shortcuts.promptToggle
        case .cancel: return shortcuts.cancel
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
                    throw PasteFailure.noTarget
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
