import AppKit

// The relay is started by sshd with no GUI session, so it is decided before NSApplication exists:
// touching AppKit's application object there fails or hangs without a window server connection.
if CommandLine.arguments.dropFirst().contains("--relay") {
    RelayBridge.run(socketPath: RemoteServer.socketURL.path)
}

let application = NSApplication.shared
let delegate = RemoteAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
