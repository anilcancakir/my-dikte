import Foundation
import Security

/// A minimal wrapper over `SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate` and `SecItemDelete`
/// for `kSecClassGenericPassword` items, one per account name, scoped to this app's bundle
/// identifier as the Keychain service.
///
/// Every item is written with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, which Apple
/// documents as the accessibility class recommended for items a background application must
/// read: this app reads a stored API key from a menu-bar process that has no foreground window,
/// so the foreground-only `...WhenUnlockedThisDeviceOnly` class would fail exactly the reads this
/// app needs. Nothing here sets `kSecAttrSynchronizable`, so a stored value never leaves this
/// device through iCloud Keychain sync. Following
/// `references/VoiceInk/VoiceInk/Services/KeychainService.swift:1-247` for the wrapper shape and
/// the three-way read result, trimmed to the single accessibility class and the single, non-
/// syncing Keychain namespace this app actually uses.
enum KeychainStore {
    /// Distinguishes "no such account" from "the Keychain returned a non-success status",
    /// because those two failures need different messages to the user: one means "add a key",
    /// the other means the Keychain is locked or otherwise unavailable right now.
    enum ReadResult: Equatable {
        case found(String)
        case missing
        case unavailable(OSStatus)
    }

    private static let service = BundleInfo.bundleIdentifier

    /// Stores `value` under `account`, updating an existing item in place or adding a new one.
    @discardableResult
    static func store(_ value: String, forAccount account: String) -> Bool {
        guard let data = value.data(using: .utf8) else {
            return false
        }

        let query = baseQuery(forAccount: account)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        guard updateStatus == errSecItemNotFound else {
            return false
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    /// Reads the value stored under `account`, distinguishing missing from unavailable.
    static func read(forAccount account: String) -> ReadResult {
        var query = baseQuery(forAccount: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                return .unavailable(errSecDecode)
            }
            return .found(value)
        case errSecItemNotFound:
            return .missing
        default:
            return .unavailable(status)
        }
    }

    /// Deletes the item stored under `account`. Deleting an account that is already missing is
    /// not an error: the caller's intent (this account should hold no value) is already true.
    @discardableResult
    static func delete(forAccount account: String) -> Bool {
        let status = SecItemDelete(baseQuery(forAccount: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(forAccount account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
