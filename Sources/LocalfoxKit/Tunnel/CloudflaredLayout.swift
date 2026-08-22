import Foundation

/// Where the bundled `cloudflared` lives.
///
/// Thinner than `CaddyLayout` because a quick tunnel owns no state: no storage
/// root, no CA, no admin socket, no config file. It reads its credentials from
/// the response to a single API call and holds them in memory for the life of
/// the process.
public enum CloudflaredLayout {
    /// Prefers the copy inside the app bundle, falling back to the checked-out
    /// `Vendor/` copy so the CLI works from a source tree.
    ///
    /// There is no privileged variant of this lookup, and there must never be.
    /// `CaddyLayout` needs `productionBinary()` because the root daemon executes
    /// Caddy; cloudflared only ever runs as the user, so the fallback that would
    /// be a privilege escalation there is merely a convenience here.
    public static func binary() -> URL {
        let inBundle = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cloudflared")
        if FileManager.default.isExecutableFile(atPath: inBundle.path) { return inBundle }

        var directory = URL(fileURLWithPath: CommandLine.arguments.first ?? ".")
            .deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("Vendor/cloudflared/cloudflared")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return inBundle
    }
}

public enum TunnelError: Error, Equatable, Sendable, LocalizedError {
    case binaryMissing(path: String)
    case spawnFailed(String)
    case noURL(log: String)
    case reported(String)

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
        case let .reported(message):
            "cloudflared failed: \(message)"
        }
    }
}
