import Foundation
import Security

/// The Mach service the root daemon vends, and the launchd label that owns it.
public enum HelperIdentity {
    public static let machServiceName = "net.kandera.localfox.helper"
    public static let launchdLabel = "net.kandera.localfox.helper"
    public static let plistName = "net.kandera.localfox.helper.plist"
    public static let appBundleIdentifier = "net.kandera.localfox"

    /// The code requirement the helper checks every connecting client against.
    ///
    /// A root Mach service that accepts any local peer is a privilege
    /// escalation, so this is not optional. `anchor apple generic` pins it to
    /// the real Apple root, and the OU field carries the Team ID, so another
    /// developer's signed binary cannot connect.
    ///
    /// The team is passed in rather than written here. A constant in source has
    /// to be kept in step with whatever identity actually signed the build, and
    /// when it drifts the boundary either stops working or, worse, trusts the
    /// wrong team. The helper reads its own.
    public static func clientRequirement(team: String) -> String {
        """
        anchor apple generic \
        and identifier "\(appBundleIdentifier)" \
        and certificate leaf[subject.OU] = "\(team)"
        """
    }

    /// The Team ID that signed the running process.
    ///
    /// The helper and the app ship in one bundle and are always signed together,
    /// so the helper's own team is exactly the team it should require of its
    /// client. Returns nil for an unsigned or ad hoc signed build, which is what
    /// a local `make app` produces; the caller decides what to do about that.
    public static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let details = information as? [String: Any] else { return nil }

        return details[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Why `SMAppService.daemon` registration cannot succeed for this build.
    ///
    /// Checked before registering rather than after failing, because launchd
    /// reports `kSMErrorAlreadyRegistered` for a stale registration and nothing
    /// at all for a build it will never accept. Both look identical to a user
    /// pressing a button that does nothing.
    public enum RegistrationBlocker: Hashable, Sendable {
        /// launchd resolves `BundleProgram` against the registering bundle, so a
        /// daemon can only be registered from an app installed in /Applications.
        case notInApplications(String)
        /// An ad hoc signature carries no Team ID, so `clientRequirement` cannot
        /// be built and `HelperService` would refuse every connection anyway.
        case noTeamIdentifier

        public var message: String {
            switch self {
            case let .notInApplications(path):
                "Localfox is running from \(path). macOS only registers a privileged "
                    + "helper for an app in /Applications. Move Localfox there, then reopen it."
            case .noTeamIdentifier:
                "This build is ad hoc signed and carries no Team ID, so its helper would "
                    + "refuse every connection. Sign it with a development or Developer ID identity."
            }
        }
    }

    /// Injectable so both branches are testable without moving the test bundle.
    public static func registrationBlocker(
        bundleURL: URL = Bundle.main.bundleURL,
        teamIdentifier: String? = currentTeamIdentifier()
    ) -> RegistrationBlocker? {
        let path = bundleURL.resolvingSymlinksInPath().path
        guard path.hasPrefix("/Applications/") else {
            return .notInApplications(bundleURL.deletingLastPathComponent().path)
        }
        guard teamIdentifier != nil else { return .noTeamIdentifier }
        return nil
    }
}

/// The API the unprivileged app may invoke on the root daemon.
///
/// Every method takes typed values, never a config blob. The app cannot express
/// an upstream host, a listen address, a filesystem path, or a Caddy handler
/// across this boundary, so a compromised app process still cannot make the
/// daemon proxy to anything but loopback. That property is the security model;
/// validating a JSON payload instead would only be a promise.
@objc public protocol LocalfoxHelperProtocol {
    /// Returns the helper's version and whether Caddy is currently up.
    ///
    /// The app compares the version against its own on every launch, because
    /// launchd keeps serving a stale helper until the service is re-registered.
    func ping(reply: @escaping (String, Bool) -> Void)

    /// Replaces the full route table. `routes` is a JSON-encoded `[ProxyRoute]`.
    ///
    /// Encoded rather than passed as objects because `NSXPCConnection` would
    /// otherwise need an allow-list of classes; `ProxyRoute` validates on decode,
    /// so a hand-crafted payload cannot survive the trip.
    ///
    /// - Parameter recordsRequests: Turns per-request logging on. A bool and not
    ///   a log path, so the app still cannot name a file across this boundary.
    func setRoutes(_ routes: Data, recordsRequests: Bool, reply: @escaping (String?) -> Void)

    /// Repoints one route at a new local port, leaving every sibling route,
    /// listener and cached certificate untouched.
    func setUpstream(routeID: String, port: Int, reply: @escaping (String?) -> Void)

    func stopProxy(reply: @escaping (String?) -> Void)

    /// The PEM of the local CA root, so the app can show its fingerprint and
    /// evaluate trust without needing root itself.
    func exportRootCA(reply: @escaping (Data?, String?) -> Void)

    /// Installs the root into the System keychain and marks it trusted for SSL.
    /// Only ever called from an explicit user action.
    func installRootCATrust(reply: @escaping (String?) -> Void)

    /// Removes a root by fingerprint, so it can never delete a different CA
    /// that happens to share a subject name.
    func removeRootCATrust(sha256Hex: String, reply: @escaping (String?) -> Void)

    /// The last lines of Caddy's log, for the diagnostics pane.
    func caddyLog(lines: Int, reply: @escaping (String) -> Void)

    /// The last lines of the access log, for the requests panel.
    ///
    /// Read through the helper for the same reason as `caddyLog`: the storage
    /// root is `0700 root:admin`, so the app cannot open the file itself.
    func accessLog(lines: Int, reply: @escaping (String) -> Void)
}

/// What the app knows about the helper right now.
///
/// `enabled` and `healthy` are separate states on purpose: launchd reporting a
/// service as enabled says only that it is eligible to run, not that it is
/// answering or that Caddy came up.
public enum HelperState: Hashable, Sendable {
    case notRegistered
    case requiresApproval
    case enabledButUnreachable
    case versionMismatch(expected: String, found: String)
    case ready(version: String, caddyRunning: Bool)

    public var needsUserAction: Bool {
        switch self {
        case .notRegistered, .requiresApproval: true
        case .enabledButUnreachable, .versionMismatch, .ready: false
        }
    }

    /// Localfox has no unprivileged fallback. A `:8443` URL would break the one
    /// promise the product makes, and users would hardcode it into their configs,
    /// so the app shows a setup wall until this is true.
    public var canServe: Bool {
        if case .ready = self { return true }
        return false
    }
}
