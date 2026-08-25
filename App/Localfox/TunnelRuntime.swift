import Darwin
import Foundation
import LocalfoxKit

/// Owns every public tunnel Localfox has opened.
///
/// A sibling of `ServiceRuntime`, keyed by the same service ids, and an actor
/// for the same reason: the UI can ask to stop sharing while the task watching
/// for the URL is still in flight, and both mutate the same record.
///
/// The two are kept apart rather than merged because their lifetimes nest
/// rather than match. A service outlives its tunnel, a tunnel must never
/// outlive its service, and `AppState` is the only place that knows both.
actor TunnelRuntime {
    /// What Localfox knows about one open tunnel.
    private struct Running {
        let process: SpawnedProcess
        /// Which of the two modes this is, because the log says different things
        /// about each one and only the quick one carries its address in there.
        let plan: TunnelPlan
        /// The process group of the dev server this tunnel dials.
        ///
        /// Held so the tunnel can notice the origin dying on its own. Nothing
        /// else would: `ServiceRuntime` stops watching a service once its port
        /// is discovered, so a dev server that crashes an hour later reports no
        /// status change at all, and without this the tunnel would keep serving
        /// a public URL for a port that closed.
        let originGroup: pid_t
        /// Distinguishes this tunnel from a later one for the same service.
        ///
        /// Teardown is asynchronous, so a stop and a fresh share can overlap:
        /// the old record is already gone while its `terminate` is still
        /// escalating, and a new one has taken its place. Without a generation
        /// the old teardown's `.off` lands after the new tunnel's `.live` and
        /// hides a share that is actually open.
        let generation: Int
        var log: LogBuffer
        var watch: Task<Void, Never>?
        var drain: Task<Void, Never>?
        /// Set once the banner has been read, so a later log chunk cannot
        /// report a second URL for a tunnel that already has one.
        var url: URL?
    }

    /// cloudflared spends about eight seconds requesting the tunnel and
    /// registering a connection. Well past that, but still short enough that a
    /// wedged process surfaces as a failure rather than a spinner nobody
    /// interrupts.
    private static let urlTimeout: Duration = .seconds(45)

    private var running: [UUID: Running] = [:]
    /// Terminations still escalating, by generation.
    ///
    /// A record is removed before its process is signalled, so without this a
    /// caller that is about to let the app exit sees an empty table and quits
    /// while a cloudflared is still being killed.
    private var teardowns: [Int: Task<Void, Never>] = [:]
    private var generations = 0
    private let onStatus: @Sendable (UUID, TunnelStatus) -> Void

    /// No `onLog` counterpart to `ServiceRuntime`'s. The buffer exists only so
    /// the hostname can be parsed out of it, and a failure already carries its
    /// tail in the reported message, so there is nothing for the interface to
    /// subscribe to.
    init(onStatus: @escaping @Sendable (UUID, TunnelStatus) -> Void) {
        self.onStatus = onStatus
    }

    func isRunning(_ id: UUID) -> Bool { running[id] != nil }

    func log(for id: UUID) -> String { running[id]?.log.text ?? "" }

    // MARK: - Starting

    func start(serviceID: UUID, plan: TunnelPlan, originGroup: pid_t) async {
        guard running[serviceID] == nil else { return }
        onStatus(serviceID, .starting)

        let binary = CloudflaredLayout.binary()
        if case .ssh = plan {} else if !FileManager.default.isExecutableFile(atPath: binary.path) {
            onStatus(serviceID, .failed(
                TunnelError.binaryMissing(path: binary.path).localizedDescription
            ))
            return
        }

        let request: SpawnRequest
        switch plan {
        case let .quick(port, rewritesHost):
            request = CloudflaredCommand.request(
                binary: binary, port: port, rewriteHost: rewritesHost
            )
        case let .named(token, _):
            request = CloudflaredCommand.named(binary: binary, token: token)
        case let .ssh(target, port):
            // Not cloudflared at all, so the bundled binary check above does not
            // apply. ssh ships with macOS.
            request = SSHTunnelCommand.request(target: target, localPort: port)
        }

        let process: SpawnedProcess
        do {
            process = try ProcessSpawner.spawn(request)
        } catch {
            onStatus(serviceID, .failed(
                TunnelError.spawnFailed(error.localizedDescription).localizedDescription
            ))
            return
        }

        generations += 1
        let generation = generations
        running[serviceID] = Running(
            process: process,
            plan: plan,
            originGroup: originGroup,
            generation: generation,
            log: LogBuffer()
        )
        running[serviceID]?.drain = drainOutput(of: process, for: serviceID)
        running[serviceID]?.watch = watch(serviceID: serviceID, generation: generation, plan: plan)
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
        }
    }

    /// Guarded by generation so a drain still finishing on the old process
    /// cannot append its shutdown output, or its banner, into the log of the
    /// tunnel that replaced it.
    private func appendLog(_ text: String, for id: UUID) {
        running[id]?.log.append(text)
    }

    // MARK: - Watching

    /// Waits for the banner, then keeps watching until something dies.
    ///
    /// Two phases in one task. The second is not optional: cloudflared prints
    /// the URL before it registers a connection, so a tunnel can be reported
    /// live and then fail, and a dev server can exit at any point after.
    private func watch(serviceID: UUID, generation: Int, plan: TunnelPlan) -> Task<Void, Never> {
        Task { [weak self] in
            let deadline = ContinuousClock.now.advanced(by: Self.urlTimeout)
            while ContinuousClock.now < deadline {
                guard let self, !Task.isCancelled else { return }
                switch await self.poll(serviceID, generation: generation) {
                case .gone:
                    return
                case .pending:
                    // `ssh -N` says nothing at all when it succeeds, so the log
                    // can never report readiness for one. Asking the address
                    // itself is the only proof the forward carries a request,
                    // and it is also what catches a VPS whose sshd bound the
                    // forward to its own loopback.
                    if case let .ssh(target, _) = plan,
                       await PublicReachability.isReachable(target.publicURL) {
                        await self.reportURL(target.publicURL, for: serviceID, generation: generation)
                        await Self.hold(self, serviceID: serviceID, generation: generation)
                        return
                    }
                    // `try?` here would swallow the cancellation and spin this
                    // loop at full speed until the deadline.
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                case let .resolved(url):
                    await self.reportURL(url, for: serviceID, generation: generation)
                    await Self.hold(self, serviceID: serviceID, generation: generation)
                    return
                case let .failed(message):
                    await self.report(.failed(message), for: serviceID, generation: generation)
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            await self.reportTimeout(serviceID, generation: generation, plan: plan)
        }
    }

    /// Phase two: hold a live tunnel until cloudflared or the dev server exits.
    ///
    /// Static so the task keeps only a weak reference across a wait that lasts
    /// as long as the share does.
    private static func hold(_ runtime: TunnelRuntime, serviceID: UUID, generation: Int) async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let reason = await runtime.exitReason(serviceID, generation: generation) else {
                continue
            }
            await runtime.report(reason, for: serviceID, generation: generation)
            return
        }
    }

    private enum Poll {
        /// No record for this generation, so someone else already tore it down.
        case gone
        case pending
        case resolved(URL)
        case failed(String)
    }

    /// One actor-isolated step: read the buffer, parse it, and check the process
    /// is still alive, without the record being able to change in between.
    private func poll(_ id: UUID, generation: Int) -> Poll {
        guard let record = current(id, generation) else { return .gone }

        let text = record.log.text
        switch record.plan {
        case .quick:
            // Failure before URL. The failure message names the API endpoint
            // cloudflared could not reach, which is itself a trycloudflare.com
            // host, so checking the other way round reports a dead share as live.
            if let failure = QuickTunnelParser.failure(in: text) {
                return .failed(TunnelError.reported(failure).localizedDescription)
            }
            if let url = QuickTunnelParser.publicURL(in: text) { return .resolved(url) }
        case let .named(_, hostname):
            if let failure = NamedTunnelParser.failure(in: text) {
                return .failed(TunnelError.reported(failure).localizedDescription)
            }
            // The hostname is the one the user configured, so the only question
            // is whether the tunnel registered. Reporting it before that would
            // hand out an address that answers 502 from Cloudflare's edge.
            if NamedTunnelParser.isConnected(in: text) { return .resolved(hostname) }
        case .ssh:
            // Failure only. Readiness for an ssh forward is settled by the probe
            // in `watch`, because a successful `ssh -N` prints nothing at all.
            if let failure = SSHTunnelCommand.failure(in: text) {
                return .failed(TunnelError.sshFailed(failure).localizedDescription)
            }
        }
        // The process can die before it ever reports anything, and nothing else
        // would notice: a tunnel binds no port to poll, so without this the
        // interface sits on "Starting" until the timeout.
        guard ProcessSpawner.isAlive(record.process.processGroup) else {
            if case .ssh = record.plan {
                // ssh with BatchMode exits rather than prompting, and the reason
                // is the last thing it wrote.
                return .failed(TunnelError.sshFailed(
                    String(record.log.text.suffix(500))
                ).localizedDescription)
            }
            return .failed(noURLMessage(id))
        }
        return .pending
    }

    /// Why a live tunnel should come down, or nil while it should stay up.
    private func exitReason(_ id: UUID, generation: Int) -> TunnelStatus? {
        guard let record = current(id, generation) else { return nil }
        if !ProcessSpawner.isAlive(record.process.processGroup) {
            return .failed("The tunnel closed. \(String(record.log.text.suffix(500)))")
        }
        // The invariant this feature rests on: a public URL must never outlive
        // the port behind it.
        if !ProcessSpawner.isAlive(record.originGroup) { return .off }
        return nil
    }

    private func current(_ id: UUID, _ generation: Int) -> Running? {
        guard let record = running[id], record.generation == generation else { return nil }
        return record
    }

    /// The tail matters more than the head here: cloudflared's first log line is
    /// a paragraph of terms-of-use prose, so the front of the buffer never says
    /// anything about why the tunnel did not open.
    private func noURLMessage(_ id: UUID) -> String {
        TunnelError.noURL(log: String(log(for: id).suffix(2_000))).localizedDescription
    }

    private func reportTimeout(_ id: UUID, generation: Int, plan: TunnelPlan) async {
        guard current(id, generation) != nil else { return }
        // An ssh forward that never answered is almost always sshd's
        // GatewayPorts, which is worth saying rather than reporting a silent log.
        let message: String
        if case let .ssh(target, _) = plan {
            message = TunnelError.sshUnreachable(
                url: target.publicURL, log: String(log(for: id).suffix(1_000))
            ).localizedDescription
        } else {
            message = noURLMessage(id)
        }
        await report(.failed(message), for: id, generation: generation)
    }

    private func reportURL(_ url: URL, for id: UUID, generation: Int) {
        guard let record = current(id, generation), record.url == nil else { return }
        running[id]?.url = url
        onStatus(id, .live(url))
    }

    // MARK: - Stopping

    /// Tears the process down as well as reporting. A cloudflared that failed to
    /// get a URL, or whose origin went away, is still a live process holding a
    /// QUIC connection open.
    private func report(_ status: TunnelStatus, for id: UUID, generation: Int) async {
        guard let record = current(id, generation) else { return }
        record.drain?.cancel()
        running[id] = nil
        await beginTeardown(record, id: id, report: status).value
    }

    func stop(_ serviceID: UUID) async {
        guard let record = running[serviceID] else {
            // No record, but a teardown from a previous generation can still be
            // escalating. A caller about to quit the app has to wait for it.
            await drainTeardowns()
            return
        }

        record.watch?.cancel()
        record.drain?.cancel()
        // Cleared before the await, so a concurrent start() is free to take over
        // this service while the old process is still being signalled. The
        // generation is what keeps the two apart.
        running[serviceID] = nil
        await beginTeardown(record, id: serviceID, report: .off).value
    }

    @discardableResult
    private func beginTeardown(
        _ record: Running, id: UUID, report status: TunnelStatus
    ) -> Task<Void, Never> {
        let generation = record.generation
        let task = Task { [weak self] in
            _ = await ProcessSpawner.terminate(group: record.process.processGroup)
            await self?.finishTeardown(generation, id: id, report: status)
        }
        teardowns[generation] = task
        return task
    }

    private func finishTeardown(_ generation: Int, id: UUID, report status: TunnelStatus) {
        teardowns[generation] = nil
        // The record was cleared before signalling, so anything here now is a
        // newer tunnel for the same service. Reporting would hide it.
        guard running[id] == nil else { return }
        onStatus(id, status)
    }

    /// Stops every tunnel. Called when the app is quitting, so a public URL
    /// never outlives the thing that opened it.
    ///
    /// Concurrent for the same reason `AppState.stopAll` is: each tunnel has its
    /// own process group, and `terminate` escalates over several seconds for one
    /// unresponsive process.
    func stopAll() async {
        let ids = Array(running.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.stop(id) }
            }
        }
        await drainTeardowns()
    }

    /// Waits out every termination still escalating, including ones this call
    /// did not start.
    private func drainTeardowns() async {
        while !teardowns.isEmpty {
            for task in teardowns.values { await task.value }
        }
    }
}
