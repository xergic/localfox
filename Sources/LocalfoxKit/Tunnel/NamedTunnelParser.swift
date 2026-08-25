import Foundation

/// Decides whether a named tunnel is up, from cloudflared's log.
///
/// A quick tunnel learns its hostname from the banner, which is why
/// `QuickTunnelParser` looks for a URL. A named tunnel has no banner: the
/// hostname is the one the user configured in Cloudflare and typed into
/// Localfox, so the only open question is whether the tunnel actually
/// registered. That makes this a readiness test rather than a parser.
public enum NamedTunnelParser {
    /// True once at least one edge connection is up.
    ///
    /// `Registered tunnel connection` is printed once per connection, and
    /// cloudflared opens four. The first one is enough: the hostname resolves
    /// from that moment, and waiting for all four would leave the interface on
    /// "Sharing…" for several seconds after the share already works.
    public static func isConnected(in text: String) -> Bool {
        text.contains("Registered tunnel connection")
    }

    /// Why the tunnel will never register, if the log says so yet.
    ///
    /// Matched on phrases and never on the `ERR` level, for the reason spelled
    /// out on `QuickTunnelParser.failure`: `--config /dev/null` logs one benign
    /// `Configuration file was empty` at ERR on every healthy start, so treating
    /// the level as the signal fails every tunnel.
    public static func failure(in text: String) -> String? {
        let signals = [
            // Token problems, which are the common case: a token pasted with a
            // missing character, or one revoked in the dashboard. The first is
            // taken from a real 2026.8.2 run rather than guessed, and it is not
            // a zerolog line at all: cloudflared prints it as bare prose on its
            // own, which is why the matcher is a substring rather than a field.
            "Provided Tunnel token is not valid",
            "Unauthorized",
            "Couldn't decode Tunnel token",
            "failed to parse token",
            "Tunnel credentials file"
        ] + QuickTunnelParser.sharedSignals
        guard let match = TunnelLog.firstLine(in: text, matching: signals) else { return nil }
        return QuickTunnelParser.message(from: match.line)
    }
}
