import Foundation
import Testing
@testable import LocalfoxKit

@Suite("NamedTunnelParser")
struct NamedTunnelParserTests {
    private let registered = """
    2026-08-25T10:00:00Z INF Starting tunnel tunnelID=0d9a
    2026-08-25T10:00:01Z INF Registered tunnel connection connIndex=0 location=prg01
    """

    @Test("one registered connection is enough to call the tunnel live")
    func detectsRegistration() {
        #expect(NamedTunnelParser.isConnected(in: registered))
        #expect(!NamedTunnelParser.isConnected(in: "2026-08-25T10:00:00Z INF Starting tunnel"))
    }

    /// `--config /dev/null` logs one benign "Configuration file was empty" at
    /// ERR on every healthy start, so a parser keyed on the level fails every
    /// tunnel it is given.
    @Test("the benign empty-config error is not a failure")
    func ignoresTheEmptyConfigError() {
        let log = """
        2026-08-25T10:00:00Z ERR Configuration file /dev/null was empty
        \(registered)
        """
        #expect(NamedTunnelParser.failure(in: log) == nil)
        #expect(NamedTunnelParser.isConnected(in: log))
    }

    /// Captured verbatim from cloudflared 2026.8.2. The benign empty-config
    /// error and the real failure arrive together, which is exactly the case a
    /// level-based matcher gets wrong in both directions.
    @Test("a rejected token is read out of a real run")
    func readsARealRejection() {
        let log = """
        2026-08-25T13:21:55Z ERR Configuration file /dev/null was empty
        Provided Tunnel token is not valid.
        See 'cloudflared tunnel run --help'.
        """
        #expect(NamedTunnelParser.failure(in: log) == "Provided Tunnel token is not valid.")
    }

    @Test("a bad token is reported with cloudflared's own sentence")
    func reportsABadToken() throws {
        let log = #"""
        2026-08-25T10:00:00Z ERR Couldn't decode Tunnel token error="illegal base64 data at input byte 4"
        """#
        #expect(NamedTunnelParser.failure(in: log) == "illegal base64 data at input byte 4")
    }

    @Test("an unauthorized tunnel is a failure, not a wait")
    func reportsUnauthorized() throws {
        let log = "2026-08-25T10:00:00Z ERR Failed to serve tunnel connection error=Unauthorized"
        let failure = try #require(NamedTunnelParser.failure(in: log))
        #expect(failure.contains("Unauthorized"))
    }

    @Test("a healthy start with no verdict yet reports nothing")
    func staysSilentWhileStarting() {
        let log = "2026-08-25T10:00:00Z INF Requesting new quick Tunnel"
        #expect(NamedTunnelParser.failure(in: log) == nil)
        #expect(!NamedTunnelParser.isConnected(in: log))
    }
}
