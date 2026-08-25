import Foundation

/// Reads a public URL, or a reason there is none, out of cloudflared's log.
///
/// A quick tunnel's hostname exists nowhere else. It is assigned by the
/// `api.trycloudflare.com` response and cloudflared prints it once, inside an
/// ASCII banner, then never mentions it again. The metrics server exposes
/// readiness but not the name, so scraping the log is the only route.
public enum QuickTunnelParser {
    /// The assigned public URL, if the banner has been printed yet.
    ///
    /// Matched by shape rather than by finding the banner headline and reading
    /// the next line: the two are separate log records, so a chunked read can
    /// split them, and the box drawing has changed between releases while the
    /// hostname shape has not.
    /// Hosts under `trycloudflare.com` that are Cloudflare's own, not an
    /// assigned tunnel.
    ///
    /// `api` is the one that matters. cloudflared requests the tunnel from
    /// `https://api.trycloudflare.com/tunnel`, and when that request fails it
    /// names the endpoint in the error: `Post "https://api.trycloudflare.com…":
    /// context deadline exceeded`. Without this the failure line parses as a
    /// successful hostname and a dead share is reported live.
    private static let reservedLabels: Set<String> = ["api", "www"]

    public static func publicURL(in text: String) -> URL? {
        // A label is lowercase alphanumeric with hyphens, so the class stops on
        // the banner's padding spaces and closing pipe on its own.
        let pattern = /https:\/\/([a-z0-9]+(?:-[a-z0-9]+)*)\.trycloudflare\.com/
        for match in text.matches(of: pattern) {
            guard !reservedLabels.contains(String(match.output.1)) else { continue }
            return URL(string: String(match.output.0))
        }
        return nil
    }

    /// Failures cloudflared reports on its way to never producing a URL.
    ///
    /// Matched on specific phrases, not on the `ERR` level. `--config /dev/null`
    /// is how the run is isolated from the user's `~/.cloudflared/config.yml`,
    /// and it logs "Configuration file /dev/null was empty" at ERR on every
    /// healthy start. Treating the level as the signal would fail every tunnel.
    public static func failure(in text: String) -> String? {
        // Taken from cloudflared 2026.8.2's quick-tunnel path rather than
        // guessed, so a run that dies partway through the handshake says why
        // instead of falling through to the generic "never printed a URL".
        let signals = [
            "Failed to request quick Tunnel",
            "failed to request quick Tunnel",
            "failed to read quick-tunnel response",
            "failed to unmarshal quick Tunnel",
            "failed to parse quick Tunnel ID",
            "Cannot determine default origin certificate path"
        ]
        guard let match = TunnelLog.firstLine(in: text, matching: signals + Self.sharedSignals) else {
            return nil
        }
        return message(from: match.line)
    }

    /// Failures that are not specific to a quick tunnel, so `NamedTunnelParser`
    /// scans for them too rather than keeping its own copy.
    static let sharedSignals = [
        "Couldn't start tunnel",
        "context deadline exceeded",
        "no such host"
    ]

    /// Strips the timestamp and level so the interface shows the sentence and
    /// not the log furniture. Prefers cloudflared's own `error=` field, which is
    /// the part that says what actually went wrong.
    ///
    /// Shared with `NamedTunnelParser`: both read the same zerolog output, and
    /// two copies of this would drift the moment one of them met a new shape.
    static func message(from line: String) -> String {
        if let range = line.range(of: "error=\"") {
            return unquoted(line[range.upperBound...])
        }
        // `2026-08-22T14:39:49Z ERR <message>` -> `<message>`
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        if fields.count == 3, fields[1].allSatisfy({ $0.isUppercase }) {
            return String(fields[2])
        }
        return line
    }

    /// Reads to the closing quote of a zerolog `key="value"` field, unescaping
    /// as it goes.
    ///
    /// The inner quotes are what make this more than `firstIndex(of:)`. The
    /// error that matters most here is a wrapped Go error, and those read
    /// `error="Post \"https://api.trycloudflare.com/tunnel\": ..."`, so stopping
    /// at the first quote truncates the message to the word `Post`.
    private static func unquoted(_ field: Substring) -> String {
        var result = ""
        var escaped = false
        for character in field {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                break
            } else {
                result.append(character)
            }
        }
        return result
    }
}
