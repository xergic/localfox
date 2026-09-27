import Foundation
import LocalfoxKit
import Security

/// Trusts the Localfox root for the current user, from the app.
///
/// macOS refuses a trust settings change that nobody confirmed, even from root.
/// The helper is a LaunchDaemon with no GUI session, so its `add-trusted-cert`
/// failed with "no user interaction was possible". The app runs in the user's
/// session, where macOS can ask for the login password.
///
/// Both calls are `@concurrent` because macOS blocks the calling thread while
/// its password dialog is up, and the callers live on the main actor.
enum UserTrustStore {
    @concurrent
    static func install(pem: Data) async throws {
        let root = try TrustEvaluator.parsePEM(pem).certificate

        // SecTrust needs the root in a keychain to build the chain, because
        // Caddy never sends it.
        let addStatus = SecItemAdd(
            [kSecClass: kSecClassCertificate, kSecValueRef: root] as CFDictionary, nil
        )
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw UserTrustStoreError.add(addStatus)
        }

        let settings = [SecPolicyCreateSSL(true, nil), SecPolicyCreateBasicX509()].map { policy in
            [
                kSecTrustSettingsPolicy: policy,
                kSecTrustSettingsResult: SecTrustSettingsResult.trustRoot.rawValue
            ] as [CFString: Any]
        }
        let trustStatus = SecTrustSettingsSetTrustSettings(root, .user, settings as CFArray)
        guard trustStatus == errSecSuccess else {
            throw UserTrustStoreError.trust(trustStatus)
        }
    }

    /// Matches on fingerprint, so it can never delete a different CA that
    /// happens to share a subject name.
    @concurrent
    static func remove(fingerprint: String) async throws {
        let matches = try TrustEvaluator.installedCertificates().filter { certificate in
            RootCAEvaluator.fingerprint(of: SecCertificateCopyData(certificate) as Data) == fingerprint
        }
        for certificate in matches {
            let trustStatus = SecTrustSettingsRemoveTrustSettings(certificate, .user)
            guard trustStatus == errSecSuccess || trustStatus == errSecItemNotFound else {
                throw UserTrustStoreError.trust(trustStatus)
            }
            let deleteStatus = SecItemDelete(
                [kSecClass: kSecClassCertificate, kSecMatchItemList: [certificate]] as CFDictionary
            )
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw UserTrustStoreError.delete(deleteStatus, fingerprint: fingerprint)
            }
        }
    }
}

enum UserTrustStoreError: LocalizedError {
    case noRoot
    case add(OSStatus)
    case trust(OSStatus)
    case delete(OSStatus, fingerprint: String)

    var errorDescription: String? {
        switch self {
        case .noRoot:
            "The helper has no Localfox certificate yet. Start the proxy, then try again."
        case let .add(status):
            "macOS could not add the Localfox certificate to your login keychain (\(Self.describe(status))). "
                + "Unlock the keychain, then try again."
        case let .trust(status):
            "macOS could not change trust for the Localfox certificate (\(Self.describe(status))). "
                + "Enter your password when macOS asks, then try again."
        case let .delete(status, fingerprint):
            // Localfox 1.0.0 and 1.0.1 put the root in the System keychain, which
            // only root can change.
            "macOS could not delete the Localfox certificate (\(Self.describe(status))). "
                + "If it is in the System keychain, run: sudo security delete-certificate -Z "
                + "\(fingerprint) /Library/Keychains/System.keychain"
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)"
    }
}
