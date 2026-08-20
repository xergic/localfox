import Foundation

/// The Mach service the root daemon vends, and the launchd label that owns it.
public enum HelperIdentity {
    public static let machServiceName = "net.kandera.localfox.helper"
    public static let launchdLabel = "net.kandera.localfox.helper"
    public static let plistName = "net.kandera.localfox.helper.plist"
    public static let appBundleIdentifier = "net.kandera.localfox"
    public static let teamIdentifier = "L36HE29JXS"

    /// The code requirement the helper checks every connecting client against.
    ///
    /// A root Mach service that accepts any local peer is a privilege
    /// escalation, so this is not optional and not configurable at runtime.
    /// `anchor apple generic` pins it to the real Apple root, and the OU field
    /// carries the Team ID, so another developer's signed binary cannot connect.
    public static var clientRequirement: String {
        """
        anchor apple generic \
        and identifier "\(appBundleIdentifier)" \
        and certificate leaf[subject.OU] = "\(teamIdentifier)"
        """
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
    func setRoutes(_ routes: Data, reply: @escaping (String?) -> Void)

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
