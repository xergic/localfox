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
        /// Set before Localfox signals the group, so the pipes closing as a result
        /// read as the stop the user asked for and not as a crash.
        var isStopping = false
    }

    private var running: [UUID: Running] = [:]
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

    // MARK: - Starting

    func start(_ service: Service, projectName: String) async {
        guard running[service.id] == nil else { return }
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
            "LOCALFOX_SERVICE": service.name
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
                            await self?.appendLog(String(decoding: data, as: UTF8.self), for: id)
                        }
                    }
                }
            }
            await self?.outputClosed(for: id)
        }
    }

    /// Both pipes closed. Unless Localfox asked for it, the server ended on its
    /// own: a crash, a port already taken, a `kill` from a terminal. Without this
    /// a dead server stayed "running" and kept its proxy route to nothing.
    private func outputClosed(for id: UUID) async {
        guard let pid = running[id]?.process.pid, running[id]?.isStopping == false else { return }
        guard let reason = await ProcessSpawner.reap(pid) else { return }
        // Read again after the wait: a Stop may have started in the meantime.
        guard let record = running[id], !record.isStopping else { return }
        running[id] = nil
        record.discovery?.cancel()
        // A child the leader left behind would otherwise keep the port.
        _ = await ProcessSpawner.terminate(group: record.process.processGroup)
        onStatus(id, .failed(.init(reason: reason, output: String(record.log.text.suffix(2_000)))))
    }

    private func appendLog(_ text: String, for id: UUID) {
        running[id]?.log.append(text)
        onLog(id)
    }

    private func discoverPort(for service: Service, process: SpawnedProcess) -> Task<Void, Never> {
        Task { [weak self] in
            let discovery = PortDiscovery()
            do {
                let listener = try await discovery.waitForPort(
                    group: process.processGroup,
                    expected: service.portMode.fixedValue ?? service.expectedPort,
                    confirm: { await PortDiscovery.confirmHTTP($0, host: service.domain.value) }
                )
                // Same check the failure branch makes. A port can confirm just as
                // stop() tears the process down, and reporting .running then
                // leaves the interface showing a dead server and pushes a proxy
                // route to a port nothing is listening on.
                guard await self?.isRunning(service.id) == true else { return }
                await self?.report(
                    .running(pid: process.pid, port: listener.port), for: service.id
                )
            } catch {
                guard await self?.isRunning(service.id) == true else { return }
                let tail = await self?.log(for: service.id) ?? ""
                // Torn down before the failure is reported. A record left behind
                // made `start` return without a word, and a failed service offers
                // no Stop or Restart, so a server that lost its port to one
                // started in a terminal could never be started again.
                await self?.abandon(service.id)
                await self?.report(
                    .failed(.init(reason: .noPortDiscovered, output: String(tail.suffix(2_000)))),
                    for: service.id
                )
            }
        }
    }

    private func abandon(_ id: UUID) async {
        guard let record = running.removeValue(forKey: id) else { return }
        record.drain?.cancel()
        _ = await ProcessSpawner.terminate(group: record.process.processGroup)
    }

    private func report(_ status: ServiceStatus, for id: UUID) {
        onStatus(id, status)
    }

    // MARK: - Stopping

    func stop(_ service: Service) async {
        guard let record = running[service.id] else { return }
        running[service.id]?.isStopping = true
        onStatus(service.id, .stopping)

        record.discovery?.cancel()
        record.drain?.cancel()
        _ = await ProcessSpawner.terminate(group: record.process.processGroup)

        running[service.id] = nil
        onStatus(service.id, .stopped)
    }

    func restart(_ service: Service, projectName: String) async {
        await stop(service)
        await start(service, projectName: projectName)
    }

    /// Stops everything. Called when the app is quitting, so a dev server never
    /// outlives the thing that started it.
    func stopAll() async {
        for (id, record) in running {
            running[id]?.isStopping = true
            record.discovery?.cancel()
            record.drain?.cancel()
            _ = await ProcessSpawner.terminate(group: record.process.processGroup)
            running[id] = nil
            onStatus(id, .stopped)
        }
    }
}
