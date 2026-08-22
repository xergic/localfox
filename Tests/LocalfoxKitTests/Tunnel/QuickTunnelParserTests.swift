import Foundation
import Testing
@testable import LocalfoxKit

@Suite("QuickTunnelParser")
struct QuickTunnelParserTests {
    /// The whole point of the fixture: a real cloudflared 2026.8.2 run, banner
    /// and all, so a release that moves the box drawing fails here rather than
    /// in front of a user waiting on a share.
    private func fixture() throws -> String {
        let url = try #require(Bundle.module.url(
            forResource: "cloudflared-quick-tunnel", withExtension: "log", subdirectory: "Fixtures"
        ))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("finds the public URL in a real cloudflared log")
    func findsURLInRealLog() throws {
        let url = QuickTunnelParser.publicURL(in: try fixture())
        #expect(url == URL(string: "https://bright-purple-cat-runs.trycloudflare.com"))
    }

    /// A healthy run logs `ERR Configuration file /dev/null was empty`, because
    /// /dev/null is how the run is isolated from the user's config.yml. Matching
    /// on the level instead of on a signal would fail every single tunnel.
    @Test("does not mistake the empty-config notice for a failure")
    func emptyConfigIsNotAFailure() throws {
        #expect(QuickTunnelParser.failure(in: try fixture()) == nil)
    }

    /// The banner headline and the URL are separate log records, so a pipe read
    /// can hand over the first without the second.
    @Test("returns nil until the URL line has actually arrived")
    func nilBeforeTheURLLands() {
        let partial = """
        2026-08-22T14:39:49Z INF Requesting new quick Tunnel on trycloudflare.com...
        2026-08-22T14:39:57Z INF +------------------------------------------+
        2026-08-22T14:39:57Z INF |  Your quick Tunnel has been created! Visit it at:  |
        """
        #expect(QuickTunnelParser.publicURL(in: partial) == nil)
    }

    /// The first line of every quick tunnel run carries the terms-of-use and
    /// docs links. Neither is the tunnel.
    @Test("ignores the cloudflare.com links in the preamble")
    func ignoresPreambleLinks() {
        let preamble = """
        2026-08-22T14:39:49Z INF Thank you for trying Cloudflare Tunnel. \
        subject to the Cloudflare Online Services Terms of Use \
        (https://www.cloudflare.com/website-terms/) ... by following: \
        https://developers.cloudflare.com/cloudflare-one/connections/connect-apps
        2026-08-22T14:39:49Z INF Requesting new quick Tunnel on trycloudflare.com...
        """
        #expect(QuickTunnelParser.publicURL(in: preamble) == nil)
    }

    @Test("stops at the banner padding rather than swallowing the pipe")
    func stopsAtBannerPadding() {
        let line = "INF |  https://four-word-host-name.trycloudflare.com        |"
        #expect(
            QuickTunnelParser.publicURL(in: line)
                == URL(string: "https://four-word-host-name.trycloudflare.com")
        )
    }

    /// A wrapped Go error carries escaped inner quotes, so reading to the first
    /// `"` truncates the message to the single word `Post`.
    @Test("reads past the escaped quotes inside cloudflared's error field")
    func readsErrorField() {
        let line = """
        2026-08-22T14:39:49Z ERR Failed to request quick Tunnel \
        error="Post \\"https://api.trycloudflare.com/tunnel\\": context deadline exceeded"
        """
        #expect(
            QuickTunnelParser.failure(in: line)
                == "Post \"https://api.trycloudflare.com/tunnel\": context deadline exceeded"
        )
    }

    @Test("strips the timestamp and level when there is no error field")
    func stripsLogFurniture() {
        let line = "2026-08-22T14:39:49Z ERR Failed to request quick Tunnel"
        #expect(QuickTunnelParser.failure(in: line) == "Failed to request quick Tunnel")
    }

    /// The failure message embeds the API endpoint, which is also a
    /// `*.trycloudflare.com` host. Matching it would report a failed run as
    /// live, under a URL that serves nothing.
    @Test("never mistakes the API endpoint for the assigned tunnel")
    func ignoresAPIEndpoint() {
        let line = """
        2026-08-22T14:39:49Z ERR Failed to request quick Tunnel \
        error="Post \\"https://api.trycloudflare.com/tunnel\\": context deadline exceeded"
        """
        #expect(QuickTunnelParser.publicURL(in: line) == nil)
        #expect(QuickTunnelParser.failure(in: line) != nil)
    }

    /// Real failure strings from cloudflared's quick-tunnel path. Falling
    /// through to the generic "no URL" error hides the actual cause.
    @Test(
        "recognises the quick-tunnel failure strings",
        arguments: [
            "failed to read quick-tunnel response",
            "failed to unmarshal quick Tunnel",
            "failed to parse quick Tunnel ID"
        ]
    )
    func recognisesQuickTunnelFailures(_ signal: String) {
        let line = "2026-08-22T14:39:49Z ERR \(signal)"
        #expect(QuickTunnelParser.failure(in: line) == signal)
    }

    @Test("no failure in an empty log")
    func emptyLog() {
        #expect(QuickTunnelParser.failure(in: "") == nil)
        #expect(QuickTunnelParser.publicURL(in: "") == nil)
    }
}
