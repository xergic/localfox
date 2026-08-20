import Foundation

/// What a service is doing right now.
///
/// `detectedPort` is only meaningful in `.running`, which is why it is not a
/// property of the service: a stopped service that still advertised its last
/// port would let the proxy keep pointing at a dead upstream.
public enum ServiceStatus: Hashable, Sendable {
    case stopped
    case starting
    case running(pid: pid_t, port: Int)
    case stopping
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

    /// True while the user is waiting on something, which is what the UI
    /// disables interaction on.
    public var isTransitioning: Bool {
        switch self {
        case .starting, .stopping: true
        case .stopped, .running, .failed: false
        }
    }

    public var port: Int? {
        if case let .running(_, port) = self { return port }
        return nil
    }
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
    public var directory: URL
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

    public init(
        id: UUID = UUID(),
        name: String,
        directory: URL,
        framework: ServiceType,
        command: String,
        domain: LocalDomain,
        portMode: PortMode = .auto,
        expectedPort: Int? = nil,
        portFlagStyle: PortFlagStyle = .none,
        environment: [String: String] = [:]
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
    }

    public var url: URL? {
        URL(string: "https://\(domain.value)")
    }
}

/// One development workspace, as the user configured it.
public struct Project: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var directory: URL
    public var services: [Service]

    public init(id: UUID = UUID(), name: String, directory: URL, services: [Service] = []) {
        self.id = id
        self.name = name
        self.directory = directory
        self.services = services
    }

    public func service(id: UUID) -> Service? {
        services.first { $0.id == id }
    }

    /// Home-relative path for display, for example `~/Projects/wishfox`.
    public var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = directory.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
