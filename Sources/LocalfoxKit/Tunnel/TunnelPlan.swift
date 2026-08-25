import Foundation

/// How one service is to be shared.
///
/// The runtime takes this instead of a port so the two modes cannot be confused
/// at the call site. They differ in more than a flag: a quick tunnel dials a
/// port Localfox discovered and learns its hostname from the log, while a named
/// tunnel dials whatever the Cloudflare dashboard says and answers on a hostname
/// the user already knows.
public enum TunnelPlan: Sendable, Equatable {
    /// A free, random `*.trycloudflare.com` address for a discovered port.
    case quick(port: Int, rewritesHost: Bool)
    /// A tunnel the user created in Cloudflare, addressed by its token.
    ///
    /// No port. A tunnel run from a token is managed remotely, so the origin
    /// lives in the dashboard and Localfox cannot change it.
    case named(token: String, hostname: URL)
    /// A reverse forward to a machine the user owns. No third party at all.
    case ssh(target: SSHTunnelTarget, port: Int)

    /// What the interface calls this share.
    public var label: String {
        switch self {
        case .quick: "Quick tunnel"
        case .named: "Named tunnel"
        case .ssh: "SSH tunnel"
        }
    }
}
