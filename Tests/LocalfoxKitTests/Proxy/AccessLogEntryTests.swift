import Foundation
import Testing
@testable import LocalfoxKit

@Suite("reading Caddy's access log")
struct AccessLogEntryTests {
    // swiftlint:disable line_length
    // Copied verbatim from a real Caddy 2.11 run rather than written by hand, so
    // a release that renames a field fails here instead of in the interface. Kept
    // on one line for the same reason: reflowing it would make it a paraphrase of
    // the format instead of a sample of it. The header maps are absent because
    // the filter encoder deletes them before the line is ever written.
    private let handled = #"""
    {"level":"info","ts":1756130000.123456,"logger":"http.log.access.access","msg":"handled request","request":{"remote_ip":"127.0.0.1","remote_port":"52001","client_ip":"127.0.0.1","proto":"HTTP/1.1","method":"GET","host":"wishfox.localhost","uri":"/api/items?q=1","tls":{"resumed":false,"version":772,"server_name":"wishfox.localhost"}},"bytes_read":0,"user_id":"","duration":0.0421,"size":1536,"status":200}
    """#
    // swiftlint:enable line_length

    @Test("a handled request parses into every field the panel shows")
    func parsesAHandledRequest() throws {
        let entry = try #require(AccessLogEntry.parse(line: handled))
        #expect(entry.host == "wishfox.localhost")
        #expect(entry.method == "GET")
        #expect(entry.uri == "/api/items?q=1")
        #expect(entry.status == 200)
        #expect(entry.size == 1_536)
        #expect(entry.milliseconds == 42)
        #expect(entry.timestamp.timeIntervalSince1970 == 1_756_130_000.123456)
    }

    /// A tail that starts inside a line is the normal case, not an error: the
    /// helper reads backwards from the end of a rolling file.
    @Test("a truncated leading line is skipped, not reported")
    func skipsATruncatedLine() {
        let tail = """
        ost":"wishfox.localhost"},"status":200}
        \(handled)
        """
        let entries = AccessLogEntry.parse(tail: tail)
        #expect(entries.count == 1)
        #expect(entries.first?.uri == "/api/items?q=1")
    }

    /// The panel re-reads the tail every couple of seconds, so an id that moved
    /// with a line's position would rebuild every row on every tick.
    @Test("an entry keeps its identity as the window slides")
    func hasAStableIdentity() throws {
        let first = try #require(AccessLogEntry.parse(line: handled))
        let shifted = AccessLogEntry.parse(tail: "\(handled)\n\(handled)")
        #expect(shifted.first?.id == first.id)
        #expect(shifted.last?.id == first.id)
    }

    /// Caddy logs the Host header verbatim, and a browser includes the port
    /// whenever it is not the scheme's default. `localfox-run up` serves 8443,
    /// so an entry from the CLI would never match its own route without this.
    @Test("a host keeps its name and loses its port")
    func stripsThePort() throws {
        let line = handled.replacingOccurrences(
            of: #""host":"wishfox.localhost""#,
            with: #""host":"wishfox.localhost:8443""#
        )
        let entry = try #require(AccessLogEntry.parse(line: line))
        #expect(entry.host == "wishfox.localhost")
    }

    @Test("a line that is not a request is skipped")
    func skipsProxyEvents() {
        let event = #"{"level":"info","ts":1756130000.1,"logger":"http","msg":"server running"}"#
        #expect(AccessLogEntry.parse(line: event) == nil)
        #expect(AccessLogEntry.parse(line: "not json at all") == nil)
        #expect(AccessLogEntry.parse(line: "") == nil)
    }

    /// One log holds every route, so the host is the only thing that attributes
    /// an entry to a service.
    @Test("entries are filtered by host")
    func filtersByHost() {
        let other = handled.replacingOccurrences(of: "wishfox.localhost", with: "api.wishfox.localhost")
        let tail = "\(handled)\n\(other)"
        #expect(AccessLogEntry.parse(tail: tail, host: "wishfox.localhost").count == 1)
        #expect(AccessLogEntry.parse(tail: tail, host: "api.wishfox.localhost").count == 1)
        #expect(AccessLogEntry.parse(tail: tail).count == 2)
    }

    @Test("the tail keeps the newest entries when it exceeds the limit")
    func honoursTheLimit() throws {
        let lines = (0..<10).map {
            handled.replacingOccurrences(of: "/api/items?q=1", with: "/item/\($0)")
        }
        let entries = AccessLogEntry.parse(tail: lines.joined(separator: "\n"), limit: 3)
        #expect(entries.map(\.uri) == ["/item/7", "/item/8", "/item/9"])
    }

    /// Caddy's own redaction covers only Cookie, Authorization and friends, so
    /// the config deletes both header maps outright. Nothing downstream reads
    /// them, and this proves nothing started to.
    @Test("an entry exposes no headers to read even if a line carries them")
    func exposesNoHeaders() throws {
        let entry = try #require(AccessLogEntry.parse(line: handled))
        #expect(Mirror(reflecting: entry).children.allSatisfy {
            $0.label?.localizedCaseInsensitiveContains("header") == false
        })
    }

    @Test("a status maps to the class the row is tinted by")
    func classifiesStatus() {
        func statusClass(_ code: Int) -> AccessLogEntry.StatusClass {
            AccessLogEntry(
                id: "\(code)", timestamp: .now, host: "a.localhost", method: "GET",
                uri: "/", status: code, duration: .zero, size: 0
            ).statusClass
        }
        #expect(statusClass(204) == .success)
        #expect(statusClass(308) == .redirect)
        #expect(statusClass(404) == .clientError)
        #expect(statusClass(502) == .serverError)
        #expect(statusClass(101) == .other)
    }
}
