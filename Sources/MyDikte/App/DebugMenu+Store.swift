import AppKit

/// This step's own debug menu entries, added through Step 1's hook (`DebugMenu.register`)
/// without editing `App/DebugMenu.swift` or `App/AppDelegate.swift`, neither of which this step
/// owns.
///
/// Swift does not run arbitrary code automatically for a file that is not `main.swift`: there is
/// no supported self-registering hook (Objective-C's `+load` is explicitly rejected by the Swift
/// compiler for any class, `override` or not, confirmed by compiling it directly against this
/// toolchain). So `register()` here is a plain, explicitly-called entry point, exactly like every
/// other area's `DebugMenu+<Area>.swift`. `App/AppDelegate.swift` is edited only by Step 17,
/// which is the integration step that wires every Wave 2 area's debug menu into the real launch
/// path; until it calls `DebugMenuStore.register()`, these entries exist in the binary but do not
/// appear in the running app's Debug submenu.
@MainActor
enum DebugMenuStore {
    static func register() {
        DebugMenu.register(title: "Store: save a test key to Keychain") {
            storeDebugKey()
        }
        DebugMenu.register(title: "Store: read the test key back") {
            readDebugKey()
        }
        DebugMenu.register(title: "Store: delete the test key") {
            deleteDebugKey()
        }
    }
}

/// The Keychain account this debug entry exercises. Distinct from every account `Settings`
/// actually uses, so poking it by hand from the debug menu never disturbs a real stored key.
private let debugKeychainAccount = "debug-menu-test-key"

@MainActor
private func storeDebugKey() {
    let stored = KeychainStore.store("debug-menu-value", forAccount: debugKeychainAccount)
    print("[DebugMenu.Store] store result: \(stored)")
}

@MainActor
private func readDebugKey() {
    switch KeychainStore.read(forAccount: debugKeychainAccount) {
    case .found:
        // The value itself is never printed, per this step's rule against writing keys to stderr
        // or any log; this debug account never holds a real key anyway, but the habit is the point.
        print("[DebugMenu.Store] read result: found, no unlock prompt")
    case .missing:
        print("[DebugMenu.Store] read result: missing")
    case .unavailable(let status):
        print("[DebugMenu.Store] read result: unavailable, status \(status)")
    }
}

@MainActor
private func deleteDebugKey() {
    let deleted = KeychainStore.delete(forAccount: debugKeychainAccount)
    print("[DebugMenu.Store] delete result: \(deleted)")
}
