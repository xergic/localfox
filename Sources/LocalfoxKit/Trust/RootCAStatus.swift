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
    case expired(RootCAIdentity)
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
        case let .expired(identity): identity
        case let .trusted(identity, _): identity
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
        /// Present but untrusted, so remove and add it again rather than
        /// stacking a second copy.
        case reinstall
        /// Remove the stale root first, by fingerprint, then install the current
        /// one. Removing by name could delete someone else's CA.
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
        if current.notAfter <= now { return .expired(current) }

        guard installed.contains(where: { $0.fingerprint == current.fingerprint }) else {
            // A different Localfox root is already in the keychain, so the user
            // needs that one removed by fingerprint before this one is added.
            // Installing over the top would leave two roots with one name.
            if let previous = installed.first {
                return .stale(installed: previous, current: current)
            }
            return .notInstalled(current)
        }

        guard trustEvaluationPassed else { return .installedNotTrusted(current) }

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
