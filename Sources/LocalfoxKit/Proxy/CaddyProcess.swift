import Darwin
import Foundation

/// Where Caddy's files live and how to reach its admin API.
///
/// Every path is explicit. Caddy derives its defaults from `HOME`, and under
/// launchd that is `/var/root`, which puts the CA somewhere the user can neither
/// find nor read.
public struct CaddyLayout: Hashable, Sendable {
    public let binary: URL
    public let storageRoot: URL
    public let adminSocket: URL
    public let logFile: URL
    public let configFile: URL

    public init(binary: URL, storageRoot: URL, adminSocket: URL, logFile: URL, configFile: URL) {
        self.binary = binary
        self.storageRoot = storageRoot
        self.adminSocket = adminSocket
        self.logFile = logFile
        self.configFile = configFile
    }

    /// Unprivileged layout for `localfox-run`, entirely under Application Support.
    ///
    /// The socket path is deliberately short: a unix socket address is capped at
    /// 104 bytes on macOS, and an Application Support path plus a long name can
    /// exceed it, which fails at bind time with a misleading error.
    public static func development() -> CaddyLayout {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Localfox", isDirectory: true)
        return CaddyLayout(
            binary: Self.bundledBinary(),
            storageRoot: base.appendingPathComponent("caddy", isDirectory: true),
            adminSocket: URL(fileURLWithPath: "/tmp/localfox-admin-\(getuid()).sock"),
            logFile: base.appendingPathComponent("caddy.log"),
            configFile: base.appendingPathComponent("caddy.json")
        )
    }

    /// Root-owned layout for the launch daemon.
    public static func production() -> CaddyLayout {
        let storageRoot = URL(
            fileURLWithPath: "/Library/Application Support/Localfox/caddy",
            isDirectory: true
        )
        let runtimeRoot = URL(fileURLWithPath: "/var/run/localfox", isDirectory: true)
        return CaddyLayout(
            binary: productionBinary(),
            storageRoot: storageRoot,
            adminSocket: runtimeRoot.appendingPathComponent("caddy.sock"),
            logFile: storageRoot.appendingPathComponent("caddy.log"),
            configFile: runtimeRoot.appendingPathComponent("caddy.json")
        )
    }

    /// The Caddy the root daemon runs. Bundle only, no search and no fallback.
    ///
    /// The development lookup must never be reachable from here. `/opt/homebrew/bin`
    /// is group-writable by `admin` on a normal Mac, so a fallback to a Homebrew
    /// path would let any admin user place a binary that the daemon then executes
    /// as root. `Contents/MacOS` is inside the signed, sealed bundle.
    public static func productionBinary() -> URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/caddy")
    }

    /// Prefers the copy inside the app bundle, falling back to the checked-out
    /// `Vendor/` copy so the CLI works from a source tree.
    ///
    /// Unprivileged callers only. `production()` uses `productionBinary()`.
    public static func bundledBinary() -> URL {
        let inBundle = productionBinary()
        if FileManager.default.isExecutableFile(atPath: inBundle.path) { return inBundle }

        var directory = URL(fileURLWithPath: CommandLine.arguments.first ?? ".")
            .deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("Vendor/caddy/caddy")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return inBundle
    }
}

public enum CaddyError: Error, Equatable, Sendable, LocalizedError {
    case binaryMissing(path: String)
    case binaryNotTrusted(path: String, reason: String)
    case unsafeDirectory(path: String, reason: String)
    case portUnavailable(port: Int, holder: String?)
    case startFailed(String)
    case didNotBecomeReady(seconds: Int, log: String)

    public var errorDescription: String? {
        switch self {
        case let .binaryMissing(path):
            "The bundled Caddy binary is missing at \(path). Run `make caddy` to fetch it."
        case let .binaryNotTrusted(path, reason):
            "Refusing to run \(path) as root: \(reason)."
        case let .unsafeDirectory(path, reason):
            "Refusing to use \(path): \(reason)."
        case let .portUnavailable(port, holder):
            if let holder {
                "Port \(port) is already in use by \(holder). Stop it, then start Localfox again."
            } else {
                "Port \(port) is already in use. Stop whatever is holding it and try again."
            }
        case let .startFailed(reason):
            "Caddy did not start. \(reason)"
        case let .didNotBecomeReady(seconds, log):
            "Caddy started but its admin socket did not appear within \(seconds) seconds.\n\(log)"
        }
    }
}

/// Starts and stops the bundled Caddy.
///
/// The same supervisor serves the unprivileged CLI and the root helper; only the
/// layout and the ports differ.
public struct CaddySupervisor: Sendable {
    public let layout: CaddyLayout

    public init(layout: CaddyLayout) {
        self.layout = layout
    }

    /// Names whatever already holds a port, so the error can say which app to
    /// quit rather than only that the port is busy.
    public static func holder(ofPort port: Int) -> String? {
        let scanner = ListenerScanner()
        guard let sockets = try? scanner.scan() else { return nil }
        guard let socket = sockets.first(where: { $0.port == port }) else { return nil }

        let inspector = ProcessInspector()
        guard let process = inspector.snapshot(pid: socket.pid) else {
            return "process \(socket.pid)"
        }
        return "\(process.executableName) (pid \(socket.pid))"
    }

    public static func isPortFree(_ port: Int) -> Bool {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { return false }
        defer { close(handle) }

        var yes: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    /// Starts Caddy with a config file already on disk.
    ///
    /// A file rather than stdin so the exact config that failed is still there to
    /// look at, which is most of debugging a proxy that will not come up.
    /// - Parameter privileged: true when this is the root daemon, which turns on
    ///   the checks that only matter when the caller can be attacked through the
    ///   filesystem.
    public func start(
        configJSON: Data,
        httpPort: Int,
        httpsPort: Int,
        privileged: Bool = false
    ) async throws -> SpawnedProcess {
        guard FileManager.default.isExecutableFile(atPath: layout.binary.path) else {
            throw CaddyError.binaryMissing(path: layout.binary.path)
        }
        if privileged {
            try Self.assertSafeToExecuteAsRoot(layout.binary)
        }

        for port in [httpPort, httpsPort] where !Self.isPortFree(port) {
            throw CaddyError.portUnavailable(port: port, holder: Self.holder(ofPort: port))
        }

        // Hardened before the first privileged write, not after. Caddy reads the
        // config as root, so a redirected or writable directory here would let
        // someone else choose that config.
        try Self.prepareDirectory(layout.storageRoot, privileged: privileged)
        try Self.prepareDirectory(layout.configFile.deletingLastPathComponent(), privileged: privileged)
        try configJSON.write(to: layout.configFile, options: .atomic)
        if privileged {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: layout.configFile.path
            )
        }

        // A socket left by a killed Caddy stops the next one binding.
        try? FileManager.default.removeItem(at: layout.adminSocket)

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = layout.storageRoot.deletingLastPathComponent().path
        environment["XDG_DATA_HOME"] = layout.storageRoot.path
        environment["XDG_CONFIG_HOME"] = layout.storageRoot.path

        let process = try ProcessSpawner.spawn(SpawnRequest(
            executable: layout.binary.path,
            // No --adapter: JSON is Caddy's native format and naming it as an
            // adapter fails with "unrecognized config adapter: json".
            arguments: [layout.binary.path, "run", "--config", layout.configFile.path],
            workingDirectory: layout.storageRoot,
            environment: environment
        ))

        try await waitForAdminSocket(process: process)
        return process
    }

    private func waitForAdminSocket(process: SpawnedProcess, seconds: Int = 15) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        var captured = ""

        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: layout.adminSocket.path) { return }
            guard ProcessSpawner.isAlive(process.processGroup) else {
                let output = captured + Self.drain(process.standardError)
                throw CaddyError.startFailed(output.isEmpty ? "it exited immediately" : output)
            }
            captured += Self.drain(process.standardError)
            try? await Task.sleep(for: .milliseconds(100))
        }

        throw CaddyError.didNotBecomeReady(seconds: seconds, log: captured)
    }

    /// Reads whatever is buffered without waiting.
    ///
    /// `FileHandle.availableData` is NOT non-blocking: it waits for data or EOF.
    /// Caddy sends its log to a file, so its stderr stays silent and a readiness
    /// loop that called `availableData` would hang there forever while the proxy
    /// was in fact already up.
    private static func drain(_ handle: FileHandle) -> String {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else { return "" }

        var output = ""
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            output += String(decoding: buffer[0..<count], as: UTF8.self)
        }
        return output
    }

    public func stop(_ process: SpawnedProcess) async {
        _ = await ProcessSpawner.terminate(group: process.processGroup)
        try? FileManager.default.removeItem(at: layout.adminSocket)
    }
}

// MARK: - Filesystem safety

public extension CaddySupervisor {
    /// Refuses to execute anything that a non-root user could have replaced.
    ///
    /// Walks the whole ancestor chain, because a writable *directory* anywhere
    /// above the binary is enough to swap it, and refuses a symlink outright so
    /// the path that was checked is the path that runs.
    static func assertSafeToExecuteAsRoot(_ binary: URL) throws {
        let manager = FileManager.default
        let resolved = binary.resolvingSymlinksInPath()
        guard resolved.path == binary.standardizedFileURL.path else {
            throw CaddyError.binaryNotTrusted(
                path: binary.path, reason: "it is a symbolic link"
            )
        }

        var url = binary.standardizedFileURL
        while true {
            guard let attributes = try? manager.attributesOfItem(atPath: url.path) else { break }
            let owner = attributes[.ownerAccountID] as? UInt ?? 0
            let mode = attributes[.posixPermissions] as? Int ?? 0

            if owner != 0 {
                throw CaddyError.binaryNotTrusted(
                    path: binary.path, reason: "\(url.path) is not owned by root"
                )
            }
            // Group or world write on any ancestor means someone else can swap it.
            if mode & 0o022 != 0 {
                throw CaddyError.binaryNotTrusted(
                    path: binary.path, reason: "\(url.path) is writable by other users"
                )
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
    }

    /// Creates a directory the daemon is about to write into, or proves the one
    /// that already exists is safe. A symlink is refused rather than followed,
    /// because following one redirects a privileged write to wherever it points.
    static func prepareDirectory(_ directory: URL, privileged: Bool) throws {
        let manager = FileManager.default

        if let attributes = try? manager.attributesOfItem(atPath: directory.path) {
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw CaddyError.unsafeDirectory(
                    path: directory.path, reason: "it is a symbolic link"
                )
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw CaddyError.unsafeDirectory(
                    path: directory.path, reason: "it is not a directory"
                )
            }
            guard privileged else { return }

            let owner = attributes[.ownerAccountID] as? UInt ?? 0
            let mode = attributes[.posixPermissions] as? Int ?? 0
            guard owner == 0 else {
                throw CaddyError.unsafeDirectory(
                    path: directory.path, reason: "it is not owned by root"
                )
            }
            // Tighten rather than refuse: an earlier build may have created this
            // with the default mode, and failing to start would be unhelpful.
            if mode & 0o022 != 0 {
                try? manager.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: directory.path
                )
            }
            return
        }

        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: privileged ? [.posixPermissions: 0o700] : nil
        )
    }
}
