import Foundation
import Testing
@testable import LocalfoxKit

@Suite("CloudflaredCommand")
struct CloudflaredCommandTests {
    private let binary = URL(fileURLWithPath: "/opt/Localfox.app/Contents/MacOS/cloudflared")

    private func request(port: Int = 5173, rewriteHost: Bool = true) -> SpawnRequest {
        CloudflaredCommand.request(binary: binary, port: port, rewriteHost: rewriteHost)
    }

    /// `localhost` resolves to ::1 first, and a Vite server bound to IPv4 only
    /// answers that with a connection refused the tunnel reports as a bare 502.
    @Test("dials the loopback address, never the name")
    func dialsLoopbackAddress() {
        #expect(CloudflaredCommand.origin(port: 5173) == "http://127.0.0.1:5173")
        #expect(request().arguments.contains("http://127.0.0.1:5173"))
    }

    /// The inverse of the rule above: the header carries the name because that
    /// is what Vite's allowedHosts permits, even though the dial uses the address.
    @Test("rewrites the Host header to the name Vite allows")
    func rewritesHostHeader() {
        let arguments = request(rewriteHost: true).arguments
        let flag = try? #require(arguments.firstIndex(of: "--http-host-header"))
        #expect(flag != nil)
        #expect(arguments.contains("localhost:5173"))
    }

    @Test("omits the Host rewrite when it is turned off")
    func omitsHostRewrite() {
        let arguments = request(rewriteHost: false).arguments
        #expect(!arguments.contains("--http-host-header"))
        #expect(!arguments.contains("localhost:5173"))
    }

    /// A developer who has run `cloudflared tunnel login` has a config.yml, and
    /// an `ingress:` block in it overrides --url, which would publish a URL
    /// pointing at a service the user never shared.
    @Test("isolates the run from the user's cloudflared config")
    func isolatesUserConfig() {
        let arguments = request().arguments
        let index = arguments.firstIndex(of: "--config")
        #expect(index != nil)
        #expect(arguments[arguments.index(after: index!)] == "/dev/null")
    }

    /// The binary is sealed into a signed bundle, so an in-place self-update
    /// would break the seal.
    @Test("disables autoupdate")
    func disablesAutoupdate() {
        #expect(request().arguments.contains("--no-autoupdate"))
    }

    /// argv[0] is the executable, matching SpawnRequest.devCommand.
    @Test("passes the binary path as argv zero")
    func argvZeroIsTheBinary() {
        let request = request()
        #expect(request.executable == binary.path)
        #expect(request.arguments.first == binary.path)
    }

    /// cloudflared reads a TUNNEL_* variable for nearly every flag it takes, so
    /// a login shell exporting TUNNEL_URL would silently retarget the tunnel.
    @Test("passes a minimal environment with no TUNNEL variables")
    func minimalEnvironment() {
        let environment = request().environment
        #expect(environment.keys.sorted() == ["HOME", "PATH"])
        #expect(!environment.keys.contains { $0.hasPrefix("TUNNEL_") })
    }

    // MARK: - Named tunnels

    private var named: SpawnRequest {
        CloudflaredCommand.named(binary: binary, token: "eyJhIjoiMSJ9")
    }

    /// Arguments are world-readable through `ps`, and a tunnel token is a bearer
    /// credential for the user's Cloudflare account.
    @Test("the token travels in the environment, never in argv")
    func keepsTheTokenOutOfArgv() {
        #expect(!named.arguments.contains { $0.contains("eyJhIjoiMSJ9") })
        #expect(named.environment["TUNNEL_TOKEN"] == "eyJhIjoiMSJ9")
        #expect(named.environment.keys.sorted() == ["HOME", "PATH", "TUNNEL_TOKEN"])
    }

    @Test("a named run is still isolated from the user's cloudflared config")
    func namedIsolatesUserConfig() throws {
        let arguments = named.arguments
        let config = try #require(arguments.firstIndex(of: "--config"))
        #expect(arguments[arguments.index(after: config)] == "/dev/null")
        let run = try #require(arguments.firstIndex(of: "run"))
        // urfave/cli takes the tunnel command's own flags before the subcommand,
        // so --config after `run` would be rejected outright.
        #expect(config < run)
    }

    /// A tunnel run from a token is managed remotely: Cloudflare owns the origin
    /// and the Host header, and passing either here would be a flag cloudflared
    /// silently ignores.
    @Test("a named run passes no origin and no host rewrite")
    func namedPassesNoOrigin() {
        #expect(!named.arguments.contains("--url"))
        #expect(!named.arguments.contains("--http-host-header"))
    }

    @Test("a named run disables autoupdate and names the binary as argv zero")
    func namedMatchesTheQuickShape() {
        #expect(named.arguments.contains("--no-autoupdate"))
        #expect(named.executable == binary.path)
        #expect(named.arguments.first == binary.path)
    }
}
