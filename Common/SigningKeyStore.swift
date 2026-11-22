import Foundation
import Security

/// Signing keys in the Keychain (not the user defaults): each bulb's, by lower-case MAC, and the
/// chosen bulb's under "current" for the widgets, which read it through the App Group's keychain
/// access group. Without the App Group the app keeps its own; a Mac build without a team (which
/// can't use the data protection keychain) keeps them in the login keychain instead.
enum SigningKeyStore {
    private static let service = "nz.aaronrumpler.setPilot.signingKeys"
    static let current = "current"

    /// The data protection keychain, unless this build isn't entitled to it (a Mac build without a
    /// team gets errSecMissingEntitlement).
    private static let dataProtection: Bool = {
        #if os(macOS)
        let probe: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecUseDataProtectionKeychain as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(probe as CFDictionary, nil) != errSecMissingEntitlement
        #else
        return true
        #endif
    }()

    private static func base(_ account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        #if WIZ_APP_GROUPS
        if dataProtection, let group = SharedStore.group { q[kSecAttrAccessGroup as String] = group }
        #endif
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    static func get(_ account: String) -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns whether it's kept (or gone, for nil).
    @discardableResult
    static func set(_ key: String?, for account: String) -> Bool {
        guard let key else {
            let status = SecItemDelete(base(account) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(key.utf8)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(base(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock // widgets run while locked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    /// Every bulb's key (not "current"), by MAC.
    static func all() -> [String: String] {
        var q = base()
        q[kSecReturnAttributes as String] = true
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [:] }
        var keys: [String: String] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String, account != current,
                  let data = item[kSecValueData as String] as? Data, let key = String(data: data, encoding: .utf8) else { continue }
            keys[account] = key
        }
        return keys
    }
}
