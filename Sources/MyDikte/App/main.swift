import AppKit

// Built by hand rather than through the SwiftUI App lifecycle: an accessory menu-bar app with
// no window has nothing for a `Scene` to host, and `NSApplicationDelegateAdaptor` adds a layer
// this app does not need.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
