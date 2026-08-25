import Foundation
import LocalfoxKit

/// What the user is agreeing to when they share a service.
///
/// One constant rather than words typed at each call site, because the popover
/// and the dashboard both ask, and a warning that varies by where it is shown
/// reads as decoration rather than as the boundary it marks. Localfox's whole
/// posture is loopback-only, down to binding Caddy to explicit addresses so a
/// dev server never reaches the LAN by accident. A share is the single action
/// that crosses that line, so it is the single action that asks first.
enum SharingWarning {
    /// What every share exposes, said once.
    ///
    /// The sentence that names what a reader of the link actually gets is the
    /// one part of this that has to be right, and three copies of it is three
    /// chances for two of them to drift.
    private static let exposure = """
        Anyone with the link reaches this dev server directly. It has no \
        authentication, and it serves your source maps, your .env values and \
        every API route on it.
        """

    /// The exposure, plus what is specific to the way it is being shared.
    static func exposure(_ mode: ServiceDetailPane.ShareMode) -> String {
        """
        \(exposure)

        \(mode.caveat)
        """
    }

    /// Why the Named entry did nothing.
    static func namedTunnelUnconfigured(_ service: Service) -> String {
        """
        \(service.name) has no named tunnel yet. Add its public hostname and \
        tunnel token under Public sharing in the project's edit sheet.
        """
    }

    /// A tunnel run from a token is managed remotely, so its origin lives in the
    /// Cloudflare dashboard. Under Auto the dev server can bind a different port
    /// on every start, and the share would publish whatever last held the one
    /// written down there.
    static func namedTunnelNeedsFixedPort(_ service: Service) -> String {
        """
        \(service.name) uses an automatic port, and a named tunnel takes its \
        origin from your Cloudflare dashboard rather than from Localfox. Set a \
        fixed port here and point the tunnel's public hostname at it.
        """
    }

    /// Why the SSH entry did nothing.
    static func sshTunnelUnconfigured(_ service: Service) -> String {
        """
        \(service.name) has no SSH tunnel yet. Add the host, user and remote \
        port under Public sharing in the project's edit sheet.
        """
    }
}

private extension ServiceDetailPane.ShareMode {
    /// The half of the warning that is not true of every mode.
    var caveat: String {
        switch self {
        case .quick:
            """
            Cloudflare assigns a random address that changes each time. Sharing \
            stops when the service stops, and when Localfox quits.
            """
        case .named:
            """
            The address is the one you configured in Cloudflare, so it stays the \
            same and anybody who has it can come back. Sharing stops when the \
            service stops, and when Localfox quits.
            """
        case .ssh:
            """
            The forward is plain HTTP unless you terminate TLS on your server \
            yourself, and it is reachable by anyone who can reach that address. \
            Sharing stops when the service stops, and when Localfox quits.
            """
        }
    }
}
