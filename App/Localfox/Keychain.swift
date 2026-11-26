import Foundation
import LocalAuthentication
import Security

/// The generic passwords Localfox stores, keyed by service id.
///
/// Only tunnel credentials live here. They are the one thing Localfox holds that
/// is a secret rather than a setting, which is why they are not in
/// `projects.json` next to everything else: that file is readable, syncable and
/// meant to be copied between machines.
enum Keychain {
    private static let service = "net.kandera.Localfox.tunnel"

    struct AccessError: LocalizedError {
        var errorDescription: String? {
            "Localfox could not access the tunnel token in your Keychain. Unlock the keychain and try again."
        }
    }

    static func containsSecret(account: String) throws -> Bool {
        let query = query(for: account, allowsInteraction: false)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw AccessError() }
        return true
    }

    static func secret(account: String) throws -> String? {
        var query = query(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { throw AccessError() }
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
        guard !trimmed.isEmpty else { return deleteSecret(account: account) }
        let base = query(for: account)
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

    static func deleteSecret(account: String, allowsInteraction: Bool = true) -> Bool {
        let query = query(for: account, allowsInteraction: allowsInteraction)
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func query(for account: String, allowsInteraction: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if !allowsInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        return query
    }
}
