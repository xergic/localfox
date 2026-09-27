import Foundation
import Security

/// The generic passwords Localfox stores, keyed by service id.
///
/// Only tunnel credentials live here. They are the one thing Localfox holds that
/// is a secret rather than a setting, which is why they are not in
/// `projects.json` next to everything else: that file is readable, syncable and
/// meant to be copied between machines.
enum Keychain {
    private static let service = "net.kandera.Localfox.tunnel"

    static func secret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Writes, or removes when `secret` is nil or blank.
    ///
    /// Add-then-update rather than delete-then-add: a delete that succeeds
    /// followed by an add that fails would silently lose a credential the user
    /// believes they just saved.
    @discardableResult
    static func setSecret(_ secret: String?, account: String) -> Bool {
        let trimmed = secret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard !trimmed.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        let data = Data(trimmed.utf8)
        var insert = base
        insert[kSecValueData as String] = data
        // Localfox opens a tunnel from a menu the user may reach before they have
        // unlocked anything else, but never before first unlock after a boot.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status == errSecSuccess { return true }
        guard status == errSecDuplicateItem else { return false }
        return SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        ) == errSecSuccess
    }
}
