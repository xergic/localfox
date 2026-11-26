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
        excludingPorts: Set<Int>,
        excludingDirectories: [URL] = [],
        host: String? = nil
    ) async -> ExistingServer? {
        guard !Task.isCancelled else { return nil }
        let finder = self
        let candidates = await Task.detached {
            finder.scan(
                in: directory.path,
                excludingGroups: excludingGroups,
                excludingPorts: excludingPorts,
                excludingDirectories: excludingDirectories.map { Self.resolved($0.path) }
            )
        }.value
        guard !candidates.isEmpty, !Task.isCancelled else { return nil }
        return await confirmedServer(in: candidates, host: host)
    }

    private enum ProbeResult {
        case response(ExistingServer, Bool)
        case initialWindowElapsed
    }

    /// Give a cold dev server time to compile its first request. When another listener
    /// has already returned HTTP, preserve port ranking for the usual two-second probe
    /// window, then use the best confirmed server and cancel the remaining requests.
    private func confirmedServer(in candidates: [ExistingServer], host: String?) async -> ExistingServer? {
        await withTaskGroup(of: ProbeResult.self) { group in
            defer { group.cancelAll() }
            for server in candidates {
                group.addTask {
                    let answers = await PortDiscovery.answersHTTP(
                        port: server.port, family: server.family, host: host, timeout: .seconds(15)
                    )
                    return .response(server, answers)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return .initialWindowElapsed
            }
            var eligible = Set(candidates)
            var confirmed: Set<ExistingServer> = []
            var initialWindowElapsed = false
            for await result in group {
                guard !Task.isCancelled else { return nil }
                switch result {
                case let .response(server, true): confirmed.insert(server)
                case let .response(server, false): eligible.remove(server)
                case .initialWindowElapsed: initialWindowElapsed = true
                }
                guard let preferred = candidates.first(where: eligible.contains) else { return nil }
                if confirmed.contains(preferred) { return preferred }
                if initialWindowElapsed, let ready = ExistingServerMatcher.preferred(from: candidates, confirmed: confirmed) {
                    return ready
                }
            }
            return nil
        }
    }

    /// Blocking: one `lsof` sweep, one `sysctl`, and a few `proc_pidinfo` reads.
    private func scan(
        in directory: String,
        excludingGroups: Set<pid_t>,
        excludingPorts: Set<Int>,
        excludingDirectories: [String]
    ) -> [ExistingServer] {
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
                excludedPorts: excludingPorts,
                excludedDirectories: excludingDirectories
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
