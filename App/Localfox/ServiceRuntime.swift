import Foundation
import LocalfoxKit

/// Owns every dev server Localfox has started.
///
/// An actor because the UI can ask to stop a service while a port poll for the
/// same service is still in flight, and both mutate the same record.
actor ServiceRuntime {
    /// What Localfox knows about one running service.
    private struct Running {
        let process: SpawnedProcess
        var log: LogBuffer
        var discovery: Task<Void, Never>?
        var drain: Task<Void, Never>?
        /// A concurrent Stop, Restart or Quit must wait for the same process cleanup.
        var termination: Task<Void, Never>?
    }

    private var running: [UUID: Running] = [:]
    private var isShuttingDown = false
    private let shell: ShellEnvironment
    private let onStatus: @Sendable (UUID, ServiceStatus) -> Void
    private let onLog: @Sendable (UUID) -> Void

    init(
        shell: ShellEnvironment,
        onStatus: @escaping @Sendable (UUID, ServiceStatus) -> Void,
        onLog: @escaping @Sendable (UUID) -> Void
    ) {
        self.shell = shell
        self.onStatus = onStatus
        self.onLog = onLog
    }

    func isRunning(_ id: UUID) -> Bool { running[id] != nil }

    func log(for id: UUID) -> String { running[id]?.log.text ?? "" }

    /// Every group Localfox spawned, which is how a server it started tells
    /// itself apart from one somebody else did.
    func ownedGroups() -> Set<pid_t> { Set(running.values.map(\.process.processGroup)) }

    // MARK: - Starting

    func start(_ service: Service, projectName: String) async {
        guard !isShuttingDown, running[service.id] == nil else { return }
        onStatus(service.id, .starting)

        var environment = shell.variables
        environment["PATH"] = shell.path
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        for (key, value) in Self.localfoxVariables(for: service, projectName: projectName) {
            environment[key] = value
        }
        // Service overrides win, which is what makes them useful.
        for (key, value) in service.environment { environment[key] = value }

        var command = service.command
        if let fixed = service.portMode.fixedValue {
            let pinned = CommandBuilder.pinningPort(
                fixed, in: command, style: service.portFlagStyle
            )
            command = pinned.command
            for (key, value) in pinned.environment { environment[key] = value }
        }

        guard let directory = service.directory else {
            onStatus(service.id, .failed(.init(
                reason: .spawnFailed(errno: ENOENT),
                output: "This service has no directory to run in."
            )))
            return
        }

        let request = SpawnRequest.devCommand(
            command, in: directory, shell: shell.shell, environment: environment
        )

        let process: SpawnedProcess
        do {
            process = try ProcessSpawner.spawn(request)
        } catch {
            onStatus(service.id, .failed(.init(
                reason: .spawnFailed(errno: Int32((error as NSError).code)),
                output: error.localizedDescription
            )))
            return
        }

        running[service.id] = Running(process: process, log: LogBuffer())
        running[service.id]?.drain = drainOutput(of: process, for: service.id)
        running[service.id]?.discovery = discoverPort(for: service, process: process)
    }

    /// Built-in variables a dev server can read.
    ///
    /// `LOCALFOX_PORT` is the *expected* port, never the discovered one. Under
    /// Auto the real port is not known until after the process has started, so
    /// promising it here would be a lie.
    static func localfoxVariables(for service: Service, projectName: String) -> [String: String] {
        var variables = [
            "LOCALFOX_URL": "https://\(service.domain.value)",
            "LOCALFOX_HOST": service.domain.value,
            "LOCALFOX_PROJECT": projectName,
            "LOCALFOX_SERVICE": service.name,
            // What Stop finds a server by once it has left its process group.
            "LOCALFOX_ID": service.id.uuidString
        ]
        if let expected = service.portMode.fixedValue ?? service.expectedPort {
            variables["LOCALFOX_PORT"] = String(expected)
        }
        // Node, Bun and Deno ignore the system trust store, so a server
        // component calling fetch("https://api.…") would fail without this.
        // The cached export first, because the daemon's own copy sits in a
        // root-owned 0700 directory the child process cannot open. The CLI's
        // authority is the fallback, for a service started by `localfox-run up`.
        let roots = [CaddyLayout.userReadableRoot, CaddyLayout.development().rootCertificate]
        if let root = roots.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) {
            variables["NODE_EXTRA_CA_CERTS"] = root.path
        }
        return variables
    }

    private func drainOutput(of process: SpawnedProcess, for id: UUID) -> Task<Void, Never> {
        Task.detached { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for handle in [process.standardOutput, process.standardError] {
                    group.addTask {
                        while true {
                            let data = handle.availableData
                            if data.isEmpty { break }
                            await self?.appendLog(String(decoding: data, as: UTF8.self), for: id, pid: process.pid)
                        }
                    }
                }
            }
            await self?.outputClosed(for: id, pid: process.pid)
        }
    }

    /// Both pipes closed. Unless Localfox asked for it, the server ended on its
    /// own: a crash, a port already taken, a `kill` from a terminal. Without this
    /// a dead server stayed "running" and kept its proxy route to nothing.
    private func outputClosed(for id: UUID, pid: pid_t) async {
        guard isCurrent(id, pid: pid), let reason = await ProcessSpawner.reap(pid, within: nil),
              isCurrent(id, pid: pid), let record = running[id] else { return }
        let failure = ServiceStatus.Failure(reason: reason, output: String(record.log.text.suffix(2_000)))
        await finish(id, status: .failed(failure))
    }

    private func appendLog(_ text: String, for id: UUID, pid: pid_t) {
        guard running[id]?.process.pid == pid else { return }
        running[id]?.log.append(text)
        onLog(id)
    }

    private func isCurrent(_ id: UUID, pid: pid_t) -> Bool {
        guard let record = running[id] else { return false }
        return record.process.pid == pid && record.termination == nil
    }

    private func discoverPort(for service: Service, process: SpawnedProcess) -> Task<Void, Never> {
        Task {
            let expected = service.portMode.fixedValue ?? service.expectedPort
            guard let listener = try? await PortDiscovery().waitForHTTP(
                group: process.processGroup, expected: expected, host: service.domain.value,
                onSlowStart: { await self.noteSlowStart(for: service.id, pid: process.pid) }
            ), isCurrent(service.id, pid: process.pid) else {
                // Stop owns cancellation. The output drain reports a natural exit with its log tail.
                return
            }
            onStatus(service.id, .running(pid: process.pid, port: listener.port, family: listener.family))
        }
    }

    private func noteSlowStart(for id: UUID, pid: pid_t) {
        guard isCurrent(id, pid: pid) else { return }
        onStatus(id, .stillStarting)
    }

    /// The group first, then anything still tagged with the service's id, which
    /// is a process that called `setsid` and left the group behind.
    private func terminate(_ record: Running, id: UUID) async {
        _ = await ProcessSpawner.terminate(group: record.process.processGroup)
        let tag = id.uuidString
        await ProcessSpawner.terminate(tagged: tag, ProcessInspector().processes(taggedWith: tag))
    }

    // MARK: - Stopping

    func stop(_ service: Service) async {
        await finish(service.id, status: .stopped)
    }

    private func finish(_ id: UUID, status: ServiceStatus) async {
        guard let record = running[id] else { return }
        if let termination = record.termination {
            await termination.value
            return
        }
        if status == .stopped { onStatus(id, .stopping) }
        record.discovery?.cancel()
        record.drain?.cancel()
        let termination = Task {
            await terminate(record, id: id)
            running[id] = nil
            onStatus(id, status)
        }
        running[id]?.termination = termination
        await termination.value
    }

    func restart(_ service: Service, projectName: String) async {
        await stop(service)
        await start(service, projectName: projectName)
    }

    /// Stops everything. Called when the app is quitting, so a dev server never
    /// outlives the thing that started it.
    func stopAll() async {
        isShuttingDown = true
        for id in Array(running.keys) { await finish(id, status: .stopped) }
    }
}
