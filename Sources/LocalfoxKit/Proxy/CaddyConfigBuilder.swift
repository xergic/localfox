import Foundation

/// Builds the complete, loopback-only Caddy configuration used by the helper.
public struct CaddyConfigBuilder: Sendable {
    public struct Options: Sendable {
        public let httpPort: Int
        public let httpsPort: Int
        public let storageRoot: String
        public let logPath: String
        public let accessLogPath: String
        public let adminSocketPath: String
        public let caID: String
        public let caName: String

        public init(
            httpPort: Int = 80,
            httpsPort: Int = 443,
            storageRoot: String,
            logPath: String,
            accessLogPath: String,
            adminSocketPath: String,
            caID: String,
            caName: String
        ) {
            self.httpPort = httpPort
            self.httpsPort = httpsPort
            self.storageRoot = storageRoot
            self.logPath = logPath
            self.accessLogPath = accessLogPath
            self.adminSocketPath = adminSocketPath
            self.caID = caID
            self.caName = caName
        }
    }

    /// The logger Caddy names when access logging is on.
    ///
    /// `default_logger_name` is a suffix: Caddy emits under
    /// `http.log.access.<name>`, and the log entry has to include exactly that.
    static let accessLogName = "access"
    static var accessLoggerName: String { "http.log.access.\(accessLogName)" }

    public let options: Options

    public init(options: Options) {
        self.options = options
    }

    /// Returns pretty-printed JSON with sorted object keys for golden-file stability.
    ///
    /// - Parameter recordsRequests: Writes one JSON line per request to
    ///   `accessLogPath`. Off means the key is absent entirely rather than
    ///   present and disabled, so a config built with it off carries no trace of
    ///   the feature at all.
    public func build(routes: [ProxyRoute], recordsRequests: Bool = false) throws -> Data {
        let sortedRoutes = routes.sorted { $0.id < $1.id }
        let domains = sortedRoutes.map { $0.domain.value }
        let httpsRoutes = sortedRoutes.map(makeHTTPSRoute) + [fallbackRoute()]
        var httpsServer: [String: Any] = [
            "listen": listeners(port: options.httpsPort),
            "idle_timeout": "24h",
            "routes": httpsRoutes,
            "automatic_https": ["disable_redirects": true]
        ]
        if recordsRequests {
            // Naming the logger is what routes access entries away from the
            // default log. `should_log_credentials` is left at its default of
            // false, which is why this file is safe to keep: it records the
            // request line and the response, never an Authorization header or a
            // cookie.
            httpsServer["logs"] = ["default_logger_name": Self.accessLogName]
        }
        let config: [String: Any] = [
            "admin": [
                "listen": "unix/\(options.adminSocketPath)",
                "config": ["persist": false]
            ],
            "storage": [
                "module": "file_system",
                "root": options.storageRoot
            ],
            "logging": ["logs": logs(recordsRequests: recordsRequests)],
            "apps": [
                "http": [
                    // Without these, Caddy's automatic HTTPS logic uses the
                    // well-known 80 and 443 for the redirect listener it adds
                    // itself, and an unprivileged run dies with
                    // "listening on 127.0.0.1:80: bind: permission denied".
                    "http_port": options.httpPort,
                    "https_port": options.httpsPort,
                    "servers": [
                        "http": [
                            "listen": listeners(port: options.httpPort),
                            "routes": [redirectRoute()],
                            // This server is the redirect. Letting Caddy add its
                            // own on top would bind a second listener.
                            "automatic_https": ["disable_redirects": true]
                        ],
                        "https": httpsServer
                    ]
                ],
                "pki": [
                    "certificate_authorities": [
                        options.caID: [
                            "name": options.caName,
                            "install_trust": false
                        ]
                    ]
                ],
                "tls": [
                    "automation": [
                        "policies": [[
                            "subjects": domains,
                            "issuers": [["module": "internal", "ca": options.caID]]
                        ]]
                    ]
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    }

    /// The `logging.logs` table.
    ///
    /// The default log has to exclude the access logger as well as the access
    /// log including it. Caddy sends an entry to every log whose filters accept
    /// it, so without the exclusion every request also lands in `caddy.log` and
    /// the diagnostics pane fills with traffic instead of proxy events.
    private func logs(recordsRequests: Bool) -> [String: Any] {
        var defaultLog: [String: Any] = [
            "writer": ["output": "file", "filename": options.logPath],
            "encoder": ["format": "json"]
        ]
        guard recordsRequests else { return ["default": defaultLog] }
        defaultLog["exclude"] = [Self.accessLoggerName]
        return [
            "default": defaultLog,
            Self.accessLogName: [
                "include": [Self.accessLoggerName],
                "encoder": ["format": "json"],
                "writer": [
                    "output": "file",
                    "filename": options.accessLogPath,
                    // Explicit rather than inherited. Caddy's default keeps ten
                    // 100 MB files, which is a gigabyte of request lines for a
                    // panel that only ever shows the last few hundred.
                    "roll": true,
                    "roll_size_mb": 10,
                    "roll_keep": 2
                ]
            ]
        ]
    }

    public static func upstreamAdminPath(for route: ProxyRoute) -> String {
        "/id/svc-\(route.id)-upstream"
    }

    public static func upstreamPatchBody(port: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["dial": "127.0.0.1:\(port)"], options: [.sortedKeys])
    }

    private func makeHTTPSRoute(_ route: ProxyRoute) -> [String: Any] {
        [
            "@id": "svc-\(route.id)",
            "match": [["host": [route.domain.value]]],
            "handle": [[
                "handler": "reverse_proxy",
                "upstreams": [[
                    "@id": "svc-\(route.id)-upstream",
                    "dial": "127.0.0.1:\(route.port)"
                ]],
                "headers": [
                    "request": [
                        "set": [
                            "X-Forwarded-Host": ["{http.request.host}"],
                            "X-Forwarded-Proto": ["https"]
                        ]
                    ]
                ],
                "transport": ["protocol": "http", "versions": ["1.1"]],
                "flush_interval": -1,
                "stream_close_delay": "5m"
            ]]
        ]
    }

    private func listeners(port: Int) -> [String] {
        ["127.0.0.1:\(port)", "[::1]:\(port)"]
    }

    private func redirectRoute() -> [String: Any] {
        [
            "handle": [[
                "handler": "static_response",
                "status_code": 308,
                "headers": ["Location": ["https://{http.request.host}{http.request.uri}"]]
            ]]
        ]
    }

    private func fallbackRoute() -> [String: Any] {
        [
            "handle": [[
                "handler": "static_response",
                "status_code": 503,
                "body": "Localfox has no service for {http.request.host}."
            ]]
        ]
    }
}
