import Darwin
import Foundation

/// Looks the machine over for a server that already runs a project's folder.
/// The matching rules are in `ExistingServerMatcher`.
public struct ExistingServerFinder: Sendable {
    private let scanner: ListenerScanner
    private let inspector: ProcessInspector

    public init(scanner: ListenerScanner = ListenerScanner(), inspector: ProcessInspector = ProcessInspector()) {
        self.scanner = scanner
        self.inspector = inspector
    }

    public func find(
        in directory: URL,
        excludingGroups: Set<pid_t>,
        excludingPorts: Set<Int>
    ) async -> ExistingServer? {
        let finder = self
        let candidates = await Task.detached {
            finder.scan(in: directory.path, excludingGroups: excludingGroups, excludingPorts: excludingPorts)
        }.value
        // Every candidate at once, so a Start never waits out one timeout per port.
        // The HTTP request only when there is a choice to make.
        let checked = await withTaskGroup(of: (server: ExistingServer, answersHTTP: Bool)?.self) { group in
            for server in candidates {
                group.addTask {
                    // Caddy dials 127.0.0.1. A server bound to `::1` alone would route to a 502.
                    guard PortProbe.accepts(port: server.port) else { return nil }
                    let answers = candidates.count > 1 ? await PortDiscovery.answersHTTP(port: server.port) : false
                    return (server, answers)
                }
            }
            var found: [(server: ExistingServer, answersHTTP: Bool)] = []
            for await result in group { if let result { found.append(result) } }
            return found
        }
        let reachable = checked.map(\.server).sorted { $0.port < $1.port }
        let answering = Set(checked.filter(\.answersHTTP).map(\.server.port))
        return ExistingServerMatcher.preferred(from: reachable, answeringHTTP: answering)
    }

    /// Blocking: one `lsof` sweep, one `sysctl`, and a few `proc_pidinfo` reads.
    private func scan(in directory: String, excludingGroups: Set<pid_t>, excludingPorts: Set<Int>) -> [ExistingServer] {
        guard let sockets = try? scanner.scan(), !sockets.isEmpty else { return [] }
        var tree = ProcessTree(processes: inspector.processSkeleton())
        // The skeleton has no cwd or executable. Read them for the listeners and
        // their ancestors only, which is a handful of processes, not the machine.
        for pid in Set(sockets.map(\.pid)) {
            for relative in [pid] + tree.ancestors(of: pid).map(\.pid) {
                guard tree.process(relative)?.workingDirectory == nil,
                      let detailed = inspector.snapshot(pid: relative)
                else { continue }
                tree.replace(detailed)
            }
        }
        return ExistingServerMatcher.servers(
            sockets: sockets,
            tree: tree,
            scope: .init(
                directory: Self.resolved(directory),
                ownUID: getuid(),
                ownedGroups: excludingGroups,
                excludedPorts: excludingPorts
            ),
            processGroup: inspector.processGroup(pid:)
        )
    }

    private static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }
}
