import Foundation

/// A server somebody else already started for a project's folder.
public struct ExistingServer: Hashable, Sendable {
    public let pid: pid_t
    public let port: Int
    public let executableName: String

    public init(pid: pid_t, port: Int, executableName: String) {
        self.pid = pid
        self.port = port
        self.executableName = executableName
    }
}

/// Decides which listeners belong to a project folder. Pure over values, so the
/// rules are tested without a socket or a process.
///
/// A coding agent often runs `pnpm dev` itself. Starting the same service from
/// Localfox would then bind a second port and run the project twice.
public enum ExistingServerMatcher {
    public struct Scope: Sendable {
        /// A resolved path. A process reports its cwd with symlinks resolved, so
        /// `/tmp/app` has to arrive as `/private/tmp/app`.
        public let directory: String
        public let ownUID: uid_t
        /// Process groups Localfox spawned. A server it started itself is not
        /// "already running".
        public let ownedGroups: Set<pid_t>
        /// Ports a route already serves.
        public let excludedPorts: Set<Int>

        public init(directory: String, ownUID: uid_t, ownedGroups: Set<pid_t>, excludedPorts: Set<Int>) {
            self.directory = directory
            self.ownUID = ownUID
            self.ownedGroups = ownedGroups
            self.excludedPorts = excludedPorts
        }
    }

    /// - Parameter processGroup: Group of a pid, read only for listeners that
    ///   survive the cheaper checks.
    /// - Returns: At most one entry per port, lowest port first.
    public static func servers(
        sockets: [ListeningSocket],
        tree: ProcessTree,
        scope: Scope,
        processGroup: (pid_t) -> pid_t?
    ) -> [ExistingServer] {
        var byPort: [Int: ExistingServer] = [:]
        for socket in sockets
        where Service.isRoutablePort(socket.port) && socket.port < PortDiscovery.ephemeralFloor
            && !scope.excludedPorts.contains(socket.port) {
            guard let process = tree.process(socket.pid), process.uid == scope.ownUID,
                  isInside(scope.directory, of: process, tree: tree)
            else { continue }
            if let group = processGroup(socket.pid), scope.ownedGroups.contains(group) { continue }
            let server = ExistingServer(pid: process.pid, port: socket.port, executableName: process.executableName)
            // Both address families of one listener, or two processes sharing a
            // port, must read as one row. The lowest pid is the older one.
            if let known = byPort[socket.port], known.pid <= server.pid { continue }
            byPort[socket.port] = server
        }
        return byPort.values.sorted { $0.port < $1.port }
    }

    /// The lowest port, unless a higher one is the only one that answers HTTP. A
    /// debugger or an inspector port opens beside the server and is not one.
    public static func preferred(from servers: [ExistingServer], answeringHTTP: Set<Int>) -> ExistingServer? {
        servers.first { answeringHTTP.contains($0.port) } ?? servers.first
    }

    /// The listener's own cwd first, then its ancestors', nearest first. `pnpm`
    /// is what ran in the project and the `node` under it is what listens.
    /// Stops at a shell or a terminal, whose cwd is the user's session and says
    /// nothing about which project a server belongs to.
    private static func isInside(_ directory: String, of listener: ProcessSnapshot, tree: ProcessTree) -> Bool {
        if contains(directory, listener.workingDirectory) { return true }
        for ancestor in tree.ancestors(of: listener.pid) {
            if ProcessRole.of(ancestor) == .boundary { return false }
            if contains(directory, ancestor.workingDirectory) { return true }
        }
        return false
    }

    private static func contains(_ directory: String, _ path: String?) -> Bool {
        guard let path else { return false }
        return path == directory || path.hasPrefix(directory + "/")
    }
}
