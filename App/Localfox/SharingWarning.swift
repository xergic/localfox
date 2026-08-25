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
    static let text = """
        Anyone with the link reaches this dev server directly. It has no \
        authentication, and it serves your source maps, your .env values and \
        every API route on it.

        Cloudflare assigns a random address that changes each time. Sharing \
        stops when the service stops, and when Localfox quits.
        """

    /// The same boundary, minus the sentence that is only true of a quick tunnel.
    ///
    /// A named tunnel answers on an address the user chose and keeps, which is
    /// the point of it, so promising a random one that changes would be wrong in
    /// the one place the wording has to be right.
    static let namedText = """
        Anyone with the link reaches this dev server directly. It has no \
        authentication, and it serves your source maps, your .env values and \
        every API route on it.

        The address is the one you configured in Cloudflare, so it stays the \
        same and anybody who has it can come back. Sharing stops when the \
        service stops, and when Localfox quits.
        """

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
}
