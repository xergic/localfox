import Foundation

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
}
