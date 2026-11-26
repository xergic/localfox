import CryptoKit
import Foundation

/// A certificate authority Localfox knows about.
public struct RootCAIdentity: Hashable, Sendable {
    /// Lowercase hex SHA-256 of the DER. The only safe way to name a specific
    /// certificate: subject names are not unique and a rotated CA reuses its own.
    public let fingerprint: String
    public let commonName: String
    public let notBefore: Date
    public let notAfter: Date

    public init(fingerprint: String, commonName: String, notBefore: Date, notAfter: Date) {
        self.fingerprint = fingerprint.lowercased()
        self.commonName = commonName
        self.notBefore = notBefore
        self.notAfter = notAfter
    }
}

/// Where Localfox's local HTTPS setup currently stands.
///
/// Five distinguishable states, because each one needs a different button.
/// Collapsing them into a boolean is what produces a "trusted" badge next to a
/// browser warning.
public enum RootCAStatus: Hashable, Sendable {
    /// Caddy has never run, so there is nothing to trust yet.
    case notGenerated
    /// A root exists but no keychain has it.
    case notInstalled(RootCAIdentity)
    /// Installed, but the system does not trust it. Trust settings say deny or
    /// unspecified, which fingerprint matching alone cannot see.
    case installedNotTrusted(RootCAIdentity)
    /// A Localfox root is trusted, but it is not the one Caddy is issuing from.
    /// Happens when the CA was regenerated and the old root stayed behind.
    case stale(installed: RootCAIdentity, current: RootCAIdentity)
    case expired(RootCAIdentity, installed: RootCAIdentity?)
    case trusted(RootCAIdentity, expiresIn: TimeInterval)

    /// Whether HTTPS actually works right now for Apple-stack clients.
    public var isUsable: Bool {
        if case .trusted = self { return true }
        return false
    }

    public var identity: RootCAIdentity? {
        switch self {
        case .notGenerated: nil
        case let .notInstalled(identity): identity
        case let .installedNotTrusted(identity): identity
        case let .stale(_, current): current
        case let .expired(identity, _): identity
        case let .trusted(identity, _): identity
        }
    }

    /// The keychain entry a Remove action should target, including a superseded root.
    public var removalFingerprint: String? {
        switch self {
        case .notGenerated, .notInstalled: nil
        case let .stale(installed, _): installed.fingerprint
        case let .expired(_, installed): installed?.fingerprint
        case let .installedNotTrusted(root), let .trusted(root, _): root.fingerprint
        }
    }

    /// Installing can prompt for a password or fail after adding the new item to
    /// the keychain. Keep the old trust in place until the new settings succeed.
    /// Cleanup errors are warnings about the superseded root, separate from installation failures.
    public func install(
        fingerprint: String,
        trustCurrent: @Sendable () async throws -> Void,
        removeSuperseded: @Sendable (String) async throws -> Void
    ) async throws -> String? {
        try await trustCurrent()
        guard let old = removalFingerprint, old != fingerprint else { return nil }
        do {
            try await removeSuperseded(old)
            return nil
        } catch {
            return "The new Localfox certificate is trusted. The older certificate (SHA-256 \(old)) "
                + "could not be removed. \(error.localizedDescription)"
        }
    }

    /// The one action that moves this state forward.
    public var remedy: Remedy {
        switch self {
        case .notGenerated: .startProxy
        case .notInstalled: .install
        case .installedNotTrusted: .reinstall
        case .stale: .repair
        case .expired: .regenerate
        case .trusted: .none
        }
    }

    public enum Remedy: Hashable, Sendable {
        /// Nothing to install until Caddy has generated a CA.
        case startProxy
        case install
        /// Update trust settings for the certificate already in the keychain.
        case reinstall
        /// Trust the current root, then remove the superseded one by fingerprint.
        case repair
        case regenerate
        case none
    }
}

/// Decides the status from facts the app gathers.
///
/// Pure, so every state is reproducible in a test. Reading keychains and
/// evaluating `SecTrust` happens in the app; this only judges the result.
public enum RootCAEvaluator {
    /// Warn this far ahead of expiry. Long enough that a user who opens Localfox
    /// once a fortnight still sees it before HTTPS breaks.
    public static let expiryWarning: TimeInterval = 30 * 24 * 60 * 60

    /// - Parameters:
    ///   - current: the root Caddy is issuing from, `nil` before the CA exists.
    ///   - installed: every Localfox root found in a keychain, so a stale one
    ///     can be named and removed by its own fingerprint.
    ///   - trustEvaluationPassed: whether a real leaf issued by `current`
    ///     validated against the system trust store. This is the only reliable
    ///     signal, because a certificate can be installed and still be denied.
    ///   - now: injected so expiry is testable.
    public static func evaluate(
        current: RootCAIdentity?,
        installed: [RootCAIdentity],
        trustEvaluationPassed: Bool,
        now: Date = Date()
    ) -> RootCAStatus {
        guard let current else { return .notGenerated }

        // Expiry outranks trust: a trust evaluation against an expired root
        // fails anyway, and "expired" is the message that tells the user why.
        if current.notAfter <= now {
            let matching = installed.first { $0.fingerprint == current.fingerprint }
            return .expired(current, installed: matching ?? installed.first)
        }

        let currentInstalled = installed.contains { $0.fingerprint == current.fingerprint }
        if !currentInstalled || !trustEvaluationPassed {
            // A cancelled password prompt can leave both certificates installed
            // but only the old one trusted. Keep its fingerprint for the retry.
            if let previous = installed.first(where: { $0.fingerprint != current.fingerprint }) {
                return .stale(installed: previous, current: current)
            }
            return currentInstalled ? .installedNotTrusted(current) : .notInstalled(current)
        }

        return .trusted(current, expiresIn: current.notAfter.timeIntervalSince(now))
    }

    public static func isExpiringSoon(_ status: RootCAStatus, now: Date = Date()) -> Bool {
        guard case let .trusted(_, expiresIn) = status else { return false }
        return expiresIn <= expiryWarning
    }

    /// Lowercase hex, matching what `security` prints and what the helper
    /// expects when removing a specific root.
    public static func fingerprint(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}
