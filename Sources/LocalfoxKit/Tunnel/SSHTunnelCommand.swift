import Foundation

/// A VPS the user already has, and the port they want the share to answer on.
public struct SSHTunnelTarget: Hashable, Sendable, Codable {
    public var host: String
    public var user: String
    /// The port `sshd` listens on, not the port being forwarded.
    public var sshPort: Int
    /// The port on the VPS that the forward binds.
    public var remotePort: Int
    /// An explicit identity file, or nil to let ssh pick from the agent and the
    /// usual defaults.
    public var keyPath: String?
    /// What the share is reachable at.
    ///
    /// The user's own value rather than one derived from `host` and
    /// `remotePort`. A forward is plain HTTP, but plenty of people already have
    /// nginx or Caddy terminating TLS on that box, and only they know which.
    public var publicURL: URL

    public init(
        host: String,
        user: String,
        sshPort: Int = 22,
        remotePort: Int,
        keyPath: String? = nil,
        publicURL: URL
    ) {
        self.host = host
        self.user = user
        self.sshPort = sshPort
        self.remotePort = remotePort
        self.keyPath = keyPath
        self.publicURL = publicURL
    }

    /// What `publicURL` defaults to before the user changes it.
    public static func defaultPublicURL(host: String, remotePort: Int) -> URL? {
        URL(string: "http://\(host):\(remotePort)")
    }
}

/// Builds the `ssh` invocation for a reverse tunnel. Pure.
public enum SSHTunnelCommand {
    public static let executable = "/usr/bin/ssh"

    public static func request(
        target: SSHTunnelTarget,
        localPort: Int,
        workingDirectory: URL = FileManager.default.temporaryDirectory
    ) -> SpawnRequest {
        var arguments = [
            executable,
            // No remote command, and no tty. Without -T ssh allocates one and
            // the process sits waiting on input Localfox will never send.
            "-N", "-T",
            // Fail rather than prompt. The alternative every other tool reaches
            // for is StrictHostKeyChecking=accept-new, which trusts whatever key
            // answers the first time; here an unknown host stops the share and
            // the message says to connect once from Terminal instead.
            "-o", "BatchMode=yes",
            // Without this ssh stays up after the forward is refused, and a dead
            // share reports itself as live.
            "-o", "ExitOnForwardFailure=yes",
            // A tunnel is idle most of the time, and a NAT or a firewall drops
            // an idle connection silently.
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3"
        ]
        if let keyPath = target.keyPath, !keyPath.isEmpty {
            arguments += ["-i", keyPath]
        }
        if target.sshPort != 22 {
            arguments += ["-p", String(target.sshPort)]
        }
        // 127.0.0.1 and never localhost, for the reason on
        // `CloudflaredCommand.origin`: localhost resolves to ::1 first, and a
        // dev server bound to IPv4 only refuses that.
        arguments += ["-R", "\(target.remotePort):127.0.0.1:\(localPort)"]
        arguments.append("\(target.user)@\(target.host)")

        return SpawnRequest(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            // HOME comes with the minimal environment and is needed rather than
            // merely convenient here: ssh reads known_hosts, the agent socket and
            // ~/.ssh/config from it. Unlike cloudflared's config.yml, which can
            // silently redirect a tunnel to a service the user never shared, an
            // ssh config that rewrites a host is the user's own arrangement, so
            // it is honoured rather than isolated.
            environment: TunnelEnvironment.minimal(extra: [
                "SSH_AUTH_SOCK": ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] ?? ""
            ])
        )
    }

    /// Why the tunnel will never come up, if ssh has said so yet.
    public static func failure(in text: String) -> String? {
        let signals = [
            "Permission denied",
            "Host key verification failed",
            "remote port forwarding failed",
            "Could not resolve hostname",
            "Connection refused",
            "Connection timed out",
            "No route to host"
        ]
        guard let match = TunnelLog.firstLine(in: text, matching: signals) else { return nil }
        return hint(for: match.signal).map { "\(match.line) \($0)" } ?? match.line
    }

    /// The sentence that turns an ssh error into something to do next.
    private static func hint(for signal: String) -> String? {
        switch signal {
        case "Host key verification failed":
            """
            Localfox runs ssh in batch mode, so it will not accept a new host \
            key for you. Connect to this host once from Terminal, then share \
            again.
            """
        case "remote port forwarding failed":
            """
            Another process on the VPS already holds that port, or sshd refused \
            the bind.
            """
        case "Permission denied":
            "Check the user and the key, and that the key is loaded in your agent."
        default:
            nil
        }
    }
}
