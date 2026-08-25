import Foundation

/// The environment every tunnel process is given.
///
/// Deliberately minimal, and deliberately not the user's login environment.
/// cloudflared reads a TUNNEL_* variable for nearly every flag it takes, so
/// inheriting a shell that exports `TUNNEL_TOKEN` or `TUNNEL_URL` would silently
/// run a different tunnel than the one the user asked to share. Anything
/// Localfox does want to set goes through `extra`, which is what keeps that
/// guarantee true rather than merely intended.
enum TunnelEnvironment {
    static func minimal(extra: [String: String] = [:]) -> [String: String] {
        var environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin"
        ]
        environment.merge(extra) { _, new in new }
        // An empty value is not the same as an unset one to every program that
        // reads it, and `SSH_AUTH_SOCK=""` makes ssh look for a socket at "".
        return environment.filter { !$0.value.isEmpty }
    }
}

/// The first line of a log matching any of `signals`.
///
/// All three tunnel parsers scan the same way, and a new log shape should need
/// one edit rather than three. The caller decides what to do with the line,
/// because only it knows whether a hint belongs on the end.
enum TunnelLog {
    static func firstLine(in text: String, matching signals: [String]) -> (line: String, signal: String)? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(line)
            guard let signal = signals.first(where: { line.contains($0) }) else { continue }
            return (line, signal)
        }
        return nil
    }
}
