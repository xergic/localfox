import Foundation

/// How one service is to be shared, and everything that differs between the ways.
///
/// The runtime takes this instead of a port so the three modes cannot be confused
/// at the call site. They differ in more than a flag, and every one of those
/// differences lives here rather than as a branch in `TunnelRuntime`: how the
/// process is spawned, how the share proves itself ready, and what a failure
/// means. That is what keeps the runtime down to spawn, watch, hold and tear
/// down, with no knowledge of which mode it is running.
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

    /// What the log has said so far.
    public enum Reading: Sendable, Equatable {
        /// Nothing conclusive yet.
        case pending
        /// The share is up and answers here.
        case live(URL)
        case failed(TunnelError)
    }

    /// How to start this share.
    ///
    /// - Parameter cloudflared: The bundled binary, ignored by a mode that does
    ///   not use it.
    public func request(cloudflared: URL) -> SpawnRequest {
        switch self {
        case let .quick(port, rewritesHost):
            CloudflaredCommand.request(binary: cloudflared, port: port, rewriteHost: rewritesHost)
        case let .named(token, _):
            CloudflaredCommand.named(binary: cloudflared, token: token)
        case let .ssh(target, port):
            SSHTunnelCommand.request(target: target, localPort: port)
        }
    }

    /// Whether `request(cloudflared:)` needs the bundled binary to exist.
    ///
    /// `ssh` ships with macOS, so a missing `cloudflared` must not stop an SSH
    /// share the way it rightly stops the other two.
    public var needsCloudflared: Bool {
        if case .ssh = self { return false }
        return true
    }

    /// An address to poll when the log cannot answer, or nil when it can.
    ///
    /// `ssh -N` prints nothing at all on success, so the only proof its forward
    /// carries a request is asking the address. It is also what catches a remote
    /// `sshd` without `GatewayPorts yes`, which binds the forward to the
    /// server's own loopback and reports no error anywhere.
    public var probeURL: URL? {
        if case let .ssh(target, _) = self { return target.publicURL }
        return nil
    }

    /// What this mode makes of the log so far.
    public func reading(of log: String) -> Reading {
        switch self {
        case .quick:
            // Failure before URL. The failure message names the API endpoint
            // cloudflared could not reach, which is itself a trycloudflare.com
            // host, so checking the other way round reports a dead share as live.
            if let failure = QuickTunnelParser.failure(in: log) { return .failed(.reported(failure)) }
            if let url = QuickTunnelParser.publicURL(in: log) { return .live(url) }
        case let .named(_, hostname):
            if let failure = NamedTunnelParser.failure(in: log) { return .failed(.reported(failure)) }
            // The hostname is the one the user configured, so the only question
            // is whether the tunnel registered. Reporting it before that would
            // hand out an address that answers 502 from Cloudflare's edge.
            if NamedTunnelParser.isConnected(in: log) { return .live(hostname) }
        case .ssh:
            // Failure only. Readiness is settled by `probeURL`.
            if let failure = SSHTunnelCommand.failure(in: log) { return .failed(.sshFailed(failure)) }
        }
        return .pending
    }

    /// Why the process dying without ever going live is a failure, in this mode's
    /// own words.
    public func earlyExit(log: String) -> TunnelError {
        switch self {
        case .quick, .named: .noURL(log: String(log.suffix(2_000)))
        case .ssh: .sshFailed(String(log.suffix(500)))
        }
    }

    /// Why waiting out the deadline is a failure, in this mode's own words.
    public func timedOut(log: String) -> TunnelError {
        switch self {
        case .quick: .noURL(log: String(log.suffix(2_000)))
        case .named: .neverRegistered(log: String(log.suffix(2_000)))
        case let .ssh(target, _): .sshUnreachable(url: target.publicURL, log: String(log.suffix(1_000)))
        }
    }
}

/// The questions `TunnelRuntime` asks of a plan once the process is running.
///
/// A plan minus its credential. `TunnelPlan.named` carries a Cloudflare token,
/// which is needed once, at spawn, to build the child's environment; everything
/// after that reads only the hostname. Holding the whole plan on the running
/// record would keep the token alive for as long as the share, and capture it
/// again in the watch task's closure, for no reason at all.
public struct TunnelReader: Sendable, Equatable {
    private let plan: TunnelPlan

    public init(_ plan: TunnelPlan) {
        self.plan = plan.withoutCredentials
    }

    public var probeURL: URL? { plan.probeURL }

    public func reading(of log: String) -> TunnelPlan.Reading { plan.reading(of: log) }

    public func earlyExit(log: String) -> TunnelError { plan.earlyExit(log: log) }

    public func timedOut(log: String) -> TunnelError { plan.timedOut(log: log) }
}

extension TunnelPlan {
    /// The same plan with any secret blanked, for the parts that never need it.
    var withoutCredentials: TunnelPlan {
        if case let .named(_, hostname) = self { return .named(token: "", hostname: hostname) }
        return self
    }
}
