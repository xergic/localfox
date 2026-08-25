import Foundation

/// One request the proxy handled, read out of Caddy's JSON access log.
///
/// Pure, like `CaddyConfigBuilder`. It parses a line it is handed and never
/// opens a file, so the whole format lives in one testable place and the app
/// layer only has to decide which lines to read.
public struct AccessLogEntry: Hashable, Sendable, Identifiable {
    /// Position in the file's tail. The log carries no request id, and two
    /// requests can share a timestamp to the microsecond under load.
    public let id: Int
    public let timestamp: Date
    /// The `Host` the client asked for, without its port, which is how an entry
    /// is attributed to a service. One log holds every route, so this is the
    /// filter.
    public let host: String
    public let method: String
    public let uri: String
    public let status: Int
    public let duration: Duration
    /// Response body bytes.
    public let size: Int

    public init(
        id: Int,
        timestamp: Date,
        host: String,
        method: String,
        uri: String,
        status: Int,
        duration: Duration,
        size: Int
    ) {
        self.id = id
        self.timestamp = timestamp
        self.host = host
        self.method = method
        self.uri = uri
        self.status = status
        self.duration = duration
        self.size = size
    }

    /// Parses one line, or returns nil.
    ///
    /// nil rather than a throw for every rejection. The tail of a rolling file
    /// can start mid-line, and Caddy writes proxy events into the same encoder
    /// shape, so a line this does not understand is the normal case rather than
    /// an error worth reporting.
    public static func parse(line: some StringProtocol, id: Int) -> AccessLogEntry? {
        guard let data = String(line).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let request = object["request"] as? [String: Any],
              let status = object["status"] as? Int,
              let host = request["host"] as? String,
              let method = request["method"] as? String,
              let uri = request["uri"] as? String
        else { return nil }

        // Seconds since the epoch as a double, which is Caddy's default time
        // format. A config that sets a string format would land here as nil
        // rather than as a wrong date.
        let seconds = object["ts"] as? Double ?? 0
        let duration = object["duration"] as? Double ?? 0

        return AccessLogEntry(
            id: id,
            timestamp: Date(timeIntervalSince1970: seconds),
            host: Self.hostWithoutPort(host),
            method: method,
            uri: uri,
            status: status,
            duration: .seconds(duration),
            size: object["size"] as? Int ?? 0
        )
    }

    /// Caddy records the `Host` header verbatim, and a browser includes the port
    /// whenever it is not the scheme's default. The app serves on 443 and
    /// `localfox-run up` on 8443, so an entry from the CLI would never match its
    /// own route without this. IPv6 literals are left alone, they have no port
    /// here because Localfox only ever routes names.
    private static func hostWithoutPort(_ host: String) -> String {
        guard !host.hasPrefix("["),
              let separator = host.lastIndex(of: ":"),
              host[host.index(after: separator)...].allSatisfy(\.isNumber)
        else { return host }
        return String(host[..<separator])
    }

    /// Parses a whole tail, keeping the last `limit` entries for `host`.
    ///
    /// The first line is dropped when the caller says the tail started mid-file,
    /// matching how the helper reads the last few megabytes rather than the
    /// whole log.
    public static func parse(
        tail: String,
        host: String? = nil,
        limit: Int = 200,
        droppingFirstLine: Bool = false
    ) -> [AccessLogEntry] {
        var lines = tail.split(separator: "\n", omittingEmptySubsequences: true)
        if droppingFirstLine, !lines.isEmpty { lines.removeFirst() }
        var entries: [AccessLogEntry] = []
        for (index, line) in lines.enumerated() {
            guard let entry = parse(line: line, id: index) else { continue }
            guard host == nil || entry.host == host else { continue }
            entries.append(entry)
        }
        return Array(entries.suffix(limit))
    }
}

extension AccessLogEntry {
    /// `2xx`, `3xx`, `4xx`, `5xx`, which is all the interface needs to tint a row.
    public enum StatusClass: Sendable {
        case success
        case redirect
        case clientError
        case serverError
        case other
    }

    public var statusClass: StatusClass {
        switch status {
        case 200..<300: .success
        case 300..<400: .redirect
        case 400..<500: .clientError
        case 500..<600: .serverError
        default: .other
        }
    }

    /// Milliseconds, rounded, for display.
    public var milliseconds: Int {
        let components = duration.components
        return Int(components.seconds) * 1_000
            + Int(Double(components.attoseconds) / 1_000_000_000_000_000)
    }
}
