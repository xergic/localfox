import Foundation

/// What a service is doing right now.
///
/// `detectedPort` is only meaningful in `.running`, which is why it is not a
/// property of the service: a stopped service that still advertised its last
/// port would let the proxy keep pointing at a dead upstream.
public enum ServiceStatus: Hashable, Sendable {
    case stopped
    case starting
    /// `pid` is nil for a port route, whose listener Localfox does not own.
    case running(pid: pid_t?, port: Int)
    case stopping
    /// A port route whose port is closed. Active, because the user started it
    /// and Stop must stay reachable, but routeless: a route to a closed port
    /// serves 502s under a domain that looks configured.
    case waiting(port: Int)
    case failed(Failure)

    public struct Failure: Hashable, Sendable {
        public let reason: Reason
        /// The tail of stdout and stderr at the moment of failure. The user
        /// cannot act on an exit code alone.
        public let output: String

        public enum Reason: Hashable, Sendable {
            case exited(code: Int32)
            case signalled(signal: Int32)
            case commandNotFound(command: String)
            case noPortDiscovered
            case spawnFailed(errno: Int32)
        }

        public init(reason: Reason, output: String) {
            self.reason = reason
            self.output = output
        }
    }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var isActive: Bool {
        switch self {
        case .running, .waiting: true
        case .stopped, .starting, .stopping, .failed: false
        }
    }

    /// True while the user is waiting on something, which is what the UI
    /// disables interaction on.
    public var isTransitioning: Bool {
        switch self {
        case .starting, .stopping: true
        case .stopped, .running, .waiting, .failed: false
        }
    }

    public var port: Int? {
        if case let .running(_, port) = self { return port }
        return nil
    }
}

/// Whether Localfox runs the server or only routes to it.
public enum ServiceKind: String, Hashable, Codable, Sendable {
    /// Localfox spawns `command` and discovers the port it binds.
    case command
    /// Something else serves `portMode`'s fixed port. Localfox only watches
    /// it and routes the domain while it accepts connections.
    case portRoute
}

/// How a framework accepts a fixed port.
///
/// This is per framework rather than a single convention because Vite, Astro
/// and SvelteKit ignore `PORT` entirely, which is the trap that makes a
/// "just set PORT" implementation fail silently on half the supported stacks.
public enum PortFlagStyle: String, Hashable, Codable, Sendable {
    /// `next dev -p 3200`
    case dashP
    /// `vite --port 4200`
    case doubleDashPort
    /// `PORT=4200 <command>`
    case environmentPORT
    /// `NUXT_PORT=4200 <command>`
    case environmentNamed
    case none
}

/// How a service decides which port to use.
public enum PortMode: Hashable, Codable, Sendable {
    /// Discover the port at runtime. Preferred, and what makes a domain survive
    /// a dev server bumping itself from 3000 to 3001.
    case auto
    /// Pin the port and pass it to the command.
    case fixed(Int)

    public var fixedValue: Int? {
        if case let .fixed(port) = self { return port }
        return nil
    }
}

/// One runnable process inside a project, and the domain it answers on.
public struct Service: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    /// Absolute. For a monorepo member this is the package directory, not the
    /// repository root, so per-directory version managers resolve correctly.
    /// nil for a port route that belongs to no directory.
    public var directory: URL?
    public var framework: ServiceType
    public var command: String
    public var domain: LocalDomain
    public var portMode: PortMode
    /// A framework default or a port parsed out of the command. A hint for
    /// scoring discovered listeners, never treated as authoritative.
    public var expectedPort: Int?
    public var portFlagStyle: PortFlagStyle
    /// Service-specific overrides, merged last. Never written to the project's
    /// own .env files.
    public var environment: [String: String]
    public var kind: ServiceKind

    public init(
        id: UUID = UUID(),
        name: String,
        directory: URL?,
        framework: ServiceType,
        command: String,
        domain: LocalDomain,
        portMode: PortMode = .auto,
        expectedPort: Int? = nil,
        portFlagStyle: PortFlagStyle = .none,
        environment: [String: String] = [:],
        kind: ServiceKind = .command
    ) {
        self.id = id
        self.name = name
        self.directory = directory
        self.framework = framework
        self.command = command
        self.domain = domain
        self.portMode = portMode
        self.expectedPort = expectedPort
        self.portFlagStyle = portFlagStyle
        self.environment = environment
        self.kind = kind
    }

    /// 80 and 443 are Caddy's own listeners, so a route there proxies to itself.
    public static func isRoutablePort(_ port: Int) -> Bool {
        ProxyRoute.isValidPort(port) && port != 80 && port != 443
    }

    public static func portRoute(name: String, domain: LocalDomain, port: Int, directory: URL?) -> Service? {
        guard isRoutablePort(port) else { return nil }
        return Service(
            name: name, directory: directory, framework: .unknown, command: "",
            domain: domain, portMode: .fixed(port), kind: .portRoute
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        directory = try container.decodeIfPresent(URL.self, forKey: .directory)
        framework = try container.decode(ServiceType.self, forKey: .framework)
        command = try container.decode(String.self, forKey: .command)
        domain = try container.decode(LocalDomain.self, forKey: .domain)
        portMode = try container.decode(PortMode.self, forKey: .portMode)
        expectedPort = try container.decodeIfPresent(Int.self, forKey: .expectedPort)
        portFlagStyle = try container.decode(PortFlagStyle.self, forKey: .portFlagStyle)
        environment = try container.decode([String: String].self, forKey: .environment)
        // Absent in every file written before routes existed, and all of those were commands.
        kind = try container.decodeIfPresent(ServiceKind.self, forKey: .kind) ?? .command
        if kind == .portRoute, portMode.fixedValue.map(Self.isRoutablePort) != true {
            throw DecodingError.dataCorruptedError(
                forKey: .portMode, in: container,
                debugDescription: "A port route needs a fixed port other than 80 and 443."
            )
        }
    }

    public var url: URL? {
        URL(string: "https://\(domain.value)")
    }
}

/// One development workspace, as the user configured it.
public struct Project: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var directory: URL?
    public var services: [Service]
    /// The icon the user picked. Relative to `directory` when the file is inside
    /// the project, absolute otherwise; the leading slash tells the two apart
    /// without a second key, and the relative form keeps the store readable.
    ///
    /// nil means automatic, not blank: `IconResolver` still runs, so a project
    /// that gains a favicon later picks it up on its own.
    public var iconPath: String?

    public init(
        id: UUID = UUID(),
        name: String,
        directory: URL?,
        services: [Service] = [],
        iconPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.directory = directory
        self.services = services
        self.iconPath = iconPath
    }

    public func service(id: UUID) -> Service? {
        services.first { $0.id == id }
    }

    /// The picked icon as an absolute URL, or nil when the project is on automatic.
    public var iconURL: URL? {
        guard let iconPath else { return nil }
        if iconPath.hasPrefix("/") { return URL(fileURLWithPath: iconPath) }
        return directory?.appendingPathComponent(iconPath)
    }

    /// How a picked file should be stored: relative when it lives in the project.
    public func iconPathValue(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let base = directory?.standardizedFileURL.path else { return path }
        guard path.hasPrefix(base + "/") else { return path }
        return String(path.dropFirst(base.count + 1))
    }

    /// Home-relative path for display, for example `~/Projects/wishfox`.
    public var displayPath: String? {
        guard let directory else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = directory.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
