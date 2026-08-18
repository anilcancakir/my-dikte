import Foundation

/// Typed constants for this app's identity, so later steps read these instead of hardcoding
/// the bundle identifier or an Application Support path.
enum BundleInfo {
    static let bundleIdentifier: String = "com.anilcan.mydikte"

    static let applicationSupportDirectory: URL = {
        let base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MyDikte", isDirectory: true)
    }()
}
