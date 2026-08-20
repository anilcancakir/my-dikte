import Foundation

/// Typed constants for this app's identity, so later steps read these instead of hardcoding
/// the bundle identifier or an Application Support path.
enum BundleInfo {
    static let bundleIdentifier: String = "com.anilcan.mydikte"

    /// The name the menu bar puts after "Quit" and "Hide". macOS draws the application menu's own
    /// title from the bundle, so this is only what those two item titles read.
    static let applicationName: String = "MyDikte"

    static let applicationSupportDirectory: URL = {
        let base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MyDikte", isDirectory: true)
    }()
}
