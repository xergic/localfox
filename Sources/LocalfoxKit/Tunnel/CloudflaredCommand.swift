import Foundation

/// Builds the `cloudflared` invocations Localfox uses. Pure.
public enum CloudflaredCommand {
    /// The loopback address the tunnel dials.
    ///
    /// `127.0.0.1` and never `localhost`, which resolves to `::1` first on a
    /// normal Mac. A dev server bound to IPv4 only would then refuse the
    /// connection, and cloudflared reports that as a bare 502 with nothing in
    /// the log to say the address family was the problem.
    public static func origin(port: Int) -> String { "http://127.0.0.1:\(port)" }

    /// The value `--http-host-header` rewrites to.
    ///
    /// `localhost:<port>` rather than the `127.0.0.1` the tunnel actually dials,
    /// because Vite's `allowedHosts` permits the name and not the address.
    public static func hostHeader(port: Int) -> String { "localhost:\(port)" }

    /// - Parameter rewriteHost: Sends the origin `Host: localhost:<port>` instead
    ///   of the `*.trycloudflare.com` name. On by default because Vite and Next
    ///   reject an unknown host outright. Off is what an app that builds absolute
    ///   URLs from the header needs: Django's `ALLOWED_HOSTS`, and any OAuth
    ///   callback, want the real public name.
    public static func request(
        binary: URL,
        port: Int,
        rewriteHost: Bool,
        workingDirectory: URL = FileManager.default.temporaryDirectory
    ) -> SpawnRequest {
        var arguments = [
            binary.path,
            "tunnel",
            // Isolates the run from ~/.cloudflared/config.yml, which cloudflared
            // reads by default. A developer who has ever run `cloudflared tunnel
            // login` has one, and its keys merge into this invocation: measured
            // on a machine whose config carried a named tunnel, the credentials
            // appeared in our settings unasked. An `ingress:` block there is the
            // sharp case, because it takes precedence over `--url` outright and
            // would publish a URL pointing at a service the user never shared.
            // /dev/null logs one benign "Configuration file was empty" at ERR,
            // which is why QuickTunnelParser matches failures by signal rather
            // than by level.
            "--config", "/dev/null",
            "--url", origin(port: port),
            // The binary is sealed into a signed bundle. An in-place self-update
            // would break the seal, and on a read-only /Applications copy it
            // fails noisily for no gain.
            "--no-autoupdate",
            "--loglevel", "info"
        ]
        if rewriteHost {
            arguments += ["--http-host-header", hostHeader(port: port)]
        }

        return SpawnRequest(
            executable: binary.path,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: TunnelEnvironment.minimal()
        )
    }

    /// Runs a tunnel the user created in the Cloudflare dashboard.
    ///
    /// There is no `--url` and no `--http-host-header` here, and adding them
    /// would be a lie. A tunnel run from a token is managed remotely, so its
    /// origin and its Host header come from the dashboard and cloudflared
    /// ignores the local flags outright. That is why a named share needs a fixed
    /// port: the port is written down in Cloudflare, not here.
    public static func named(
        binary: URL,
        token: String,
        workingDirectory: URL = FileManager.default.temporaryDirectory
    ) -> SpawnRequest {
        SpawnRequest(
            executable: binary.path,
            arguments: [
                binary.path,
                "tunnel",
                // Same reason as the quick path: an `ingress:` block in the
                // user's config.yml takes precedence and would publish a
                // hostname pointing somewhere they never shared.
                "--config", "/dev/null",
                "--no-autoupdate",
                "--loglevel", "info",
                "run"
            ],
            workingDirectory: workingDirectory,
            // The token goes in the environment and never in argv. Arguments are
            // world-readable through `ps`, and this one is a bearer credential
            // for the user's Cloudflare tunnel.
            environment: TunnelEnvironment.minimal(extra: ["TUNNEL_TOKEN": token])
        )
    }
}
