import Foundation
import Testing

@testable import MyDikte

@Suite("BundleInfo")
struct BundleInfoTests {
    @Test("bundle identifier matches the Info.plist value")
    func bundleIdentifierMatchesInfoPlist() {
        #expect(BundleInfo.bundleIdentifier == "com.anilcan.mydikte")
    }

    @Test("application support directory sits under the user's Application Support folder")
    func applicationSupportDirectoryIsUnderUserDomain() {
        let expectedParent: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]

        #expect(
            BundleInfo.applicationSupportDirectory.deletingLastPathComponent().standardizedFileURL
                == expectedParent.standardizedFileURL
        )
        #expect(BundleInfo.applicationSupportDirectory.lastPathComponent == "MyDikte")
    }
}
