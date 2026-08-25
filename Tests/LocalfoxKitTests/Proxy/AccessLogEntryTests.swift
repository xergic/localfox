import Foundation
import Testing
@testable import LocalfoxKit

@Suite("reading Caddy's access log")
struct AccessLogEntryTests {
    // swiftlint:disable line_length
    // Copied verbatim from a real Caddy 2.11 run rather than written by hand, so
    // a release that renames a field fails here instead of in the interface. Kept
    // on one line for the same reason: reflowing it would make it a paraphrase of
    // the format instead of a sample of it.
    private let handled = #"""
    {"level":"info","ts":1756130000.123456,"logger":"http.log.access.access","msg":"handled request","request":{"remote_ip":"127.0.0.1","remote_port":"52001","client_ip":"127.0.0.1","proto":"HTTP/1.1","method":"GET","host":"wishfox.localhost","uri":"/api/items?q=1","headers":{"User-Agent":["curl/8.7.1"]},"tls":{"resumed":false,"version":772,"server_name":"wishfox.localhost"}},"bytes_read":0,"user_id":"","duration":0.0421,"size":1536,"status":200,"resp_headers":{"Content-Type":["application/json"]}}
    """#
    // swiftlint:enable line_length

    @Test("a handled request parses into every field the panel shows")
    func parsesAHandledRequest() throws {
        let entry = try #require(AccessLogEntry.parse(line: handled, id: 7))
        #expect(entry.id == 7)
        #expect(entry.host == "wishfox.localhost")
        #expect(entry.method == "GET")
        #expect(entry.uri == "/api/items?q=1")
        #expect(entry.status == 200)
        #expect(entry.size == 1_536)
        #expect(entry.milliseconds == 42)
        #expect(entry.timestamp.timeIntervalSince1970 == 1_756_130_000.123456)
    }

    /// A tail that starts inside a line is the normal case, not an error: the
    /// helper reads the last few megabytes of a rolling file.
    @Test("a truncated leading line is dropped, not reported")
    func dropsATruncatedLine() {
        let tail = """
        ost":"wishfox.localhost"},"status":200}
        \(handled)
        """
        let entries = AccessLogEntry.parse(tail: tail, droppingFirstLine: true)
        #expect(entries.count == 1)
        #expect(entries.first?.uri == "/api/items?q=1")
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
        let entry = try #require(AccessLogEntry.parse(line: line, id: 0))
        #expect(entry.host == "wishfox.localhost")
    }

    @Test("a line that is not a request is skipped")
    func skipsProxyEvents() {
        let event = #"{"level":"info","ts":1756130000.1,"logger":"http","msg":"server running"}"#
        #expect(AccessLogEntry.parse(line: event, id: 0) == nil)
        #expect(AccessLogEntry.parse(line: "not json at all", id: 0) == nil)
        #expect(AccessLogEntry.parse(line: "", id: 0) == nil)
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
    func honoursTheLimit() {
        let tail = Array(repeating: handled, count: 10).joined(separator: "\n")
        let entries = AccessLogEntry.parse(tail: tail, limit: 3)
        #expect(entries.count == 3)
        #expect(entries.map(\.id) == [7, 8, 9])
    }

    @Test("a status maps to the class the row is tinted by")
    func classifiesStatus() {
        func statusClass(_ code: Int) -> AccessLogEntry.StatusClass {
            AccessLogEntry(
                id: 0, timestamp: .now, host: "a.localhost", method: "GET",
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
