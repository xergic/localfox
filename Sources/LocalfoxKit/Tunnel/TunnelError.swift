import Foundation

/// Why a share did not open, in words the user can act on.
///
/// One type for all three tunnel kinds, because they land in the same
/// `TunnelStatus.failed` and the interface shows whichever came back.
public enum TunnelError: Error, Equatable, Sendable, LocalizedError {
    case binaryMissing(path: String)
    case spawnFailed(String)
    case noURL(log: String)
    case neverRegistered(log: String)
    case reported(String)
    case sshFailed(String)
    case sshUnreachable(url: URL, log: String)

    public var errorDescription: String? {
        switch self {
        case let .binaryMissing(path):
            """
            The bundled cloudflared binary is missing at \(path). \
            Run `make cloudflared` to fetch it.
            """
        case let .spawnFailed(reason):
            "cloudflared could not be started. \(reason)"
        case let .noURL(log):
            """
            cloudflared started but never printed a public URL.
            \(log)
            """
        case let .neverRegistered(log):
            """
            cloudflared never registered a tunnel connection, so \
            \(TunnelError.hostnameHint)
            \(log)
            """
        case let .reported(message):
            "cloudflared failed: \(message)"
        case let .sshFailed(message):
            "The SSH tunnel failed. \(message)"
        case let .sshUnreachable(url, log):
            """
            The SSH tunnel is connected but \(url.absoluteString) does not \
            answer. The remote sshd needs `GatewayPorts yes` for a forward to \
            listen on anything but its own loopback.
            \(log)
            """
        }
    }

    /// A named tunnel prints no URL by design, so the generic "never printed a
    /// URL" wording would send the user looking for something that was never
    /// going to appear.
    private static let hostnameHint = """
        the hostname you configured is not serving. Check that the tunnel token \
        is current and that its public hostname is enabled in Cloudflare.
        """
}
