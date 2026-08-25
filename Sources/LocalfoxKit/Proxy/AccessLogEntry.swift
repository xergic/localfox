import Foundation

/// One request the proxy handled, read out of Caddy's JSON access log.
///
/// Pure, like `CaddyConfigBuilder`. It parses a line it is handed and never
/// opens a file, so the whole format lives in one testable place and the app
/// layer only has to decide which lines to read.
public struct AccessLogEntry: Hashable, Sendable, Identifiable {
    /// Stable across polls, which is what `ForEach` needs.
    ///
    /// Derived from the entry rather than from its position, because the panel
    /// re-reads the tail every couple of seconds and a line's index inside that
    /// window moves as new requests arrive. An index would change every id on
    /// every tick and make SwiftUI rebuild all hundred rows instead of diffing
    /// them, exactly when there is enough traffic for it to matter.
    public let id: String
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
        id: String,
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
    public static func parse(line: some StringProtocol) -> AccessLogEntry? {
        // `Data(_:utf8)` rather than `String(line).data(using:)`, which copies
        // the substring into a String first. This runs once per line of a tail
        // read every couple of seconds.
        let data = Data(line.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
            // Two requests can share a timestamp to the microsecond under load,
            // so the whole line is the identity. It is what the log itself
            // offers, and it is stable by construction.
            id: String(line),
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
    /// Walks backwards and stops as soon as it has enough, because the caller
    /// only ever shows the newest entries. Read forwards this would JSON-parse
    /// every line in the window to throw all but the last hundred away, and with
    /// several services sharing one log most of those lines belong to a
    /// different host anyway.
    public static func parse(
        tail: String,
        host: String? = nil,
        limit: Int = 200
    ) -> [AccessLogEntry] {
        // A cheap substring test before the JSON decoder. The host is the field
        // that rejects most lines, and rejecting them costs a scan rather than a
        // parse. `nil` here means the caller wants every host.
        let marker = host.map { "\"host\":\"\($0)" }
        var entries: [AccessLogEntry] = []
        for line in tail.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            if let marker, !line.contains(marker) { continue }
            guard let entry = parse(line: line) else { continue }
            // The marker matches a prefix, so `wishfox.localhost` would also
            // accept `wishfox.localhost.evil.test`. The parsed host is exact.
            guard host == nil || entry.host == host else { continue }
            entries.append(entry)
            if entries.count == limit { break }
        }
        return entries.reversed()
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
        Int((duration.timeInterval * 1_000).rounded())
    }
}
