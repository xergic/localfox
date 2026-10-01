import Foundation
import LocalfoxKit
import Observation
import SwiftUI

/// Everything the interface reads.
///
/// One instance, created by the scene and injected with `.environment`.
@MainActor
@Observable
final class AppState {
    // MARK: - Configuration

    private(set) var projects: [Project] = []
    /// Live status per service. Kept apart from `Service` because a service is
    /// saved configuration and a status is not; writing one would rewrite the
    /// store on every poll tick.
    private(set) var statuses: [UUID: ServiceStatus] = [:]
    /// Live tunnel state per service, kept apart from `statuses` for the same
    /// reason that is kept apart from `Service`, and never persisted. See
    /// `TunnelStatus` for why a share must not survive a relaunch.
    private(set) var tunnels: [UUID: TunnelStatus] = [:]

    /// Owns registration and the XPC channel. Read through `helper`.
    let helperClient: HelperClient
    let appearance = Appearance()
    let preferences = Preferences()
    let tunnelTargets = TunnelTargets()

    /// Held here rather than in the dashboard's own state, because the popover
    /// asks for the sheet on a window that does not exist yet.
    var presentsPreferences = false
    private(set) var trust: RootCAStatus = .notGenerated
    private(set) var shellEnvironment: ShellEnvironment?
    private(set) var lastError: String?

    private(set) var logs: [UUID: String] = [:]
    /// Recent requests per service, parsed from the proxy's access log.
    ///
    /// Not persisted and not part of `statuses`, for the same reason a status is
    /// not part of a `Service`: this is a view of a file the helper owns, and it
    /// is only ever filled while something is looking at it.
    private(set) var requests: [UUID: [AccessLogEntry]] = [:]

    private let store: ProjectStore
    private let resolver = ShellEnvironmentResolver()
    private var runtime: ServiceRuntime?
    /// Not private only because the sharing half of `AppState` lives in
    /// `AppState+Sharing.swift`. Nothing outside this type touches it.
    var tunnelRuntime: TunnelRuntime?
    /// Not private for the same reason as `tunnelRuntime`: `AppState+Routes.swift`.
    var routeWatcher: PortRouteWatcher?

    init(store: ProjectStore = ProjectStore(), helperClient: HelperClient = HelperClient()) {
        self.store = store
        self.helperClient = helperClient
    }

    #if DEBUG
    /// Snapshot only, in place of `load()`, on a machine whose helper may not be approved.
    func adoptFixture(_ projects: [Project], statuses: [UUID: ServiceStatus], tunnels: [UUID: TunnelStatus], logs: [UUID: String]) {
        (self.projects, self.statuses, self.tunnels, self.logs) = (projects, statuses, tunnels, logs)
        trust = .trusted(RootCAIdentity(fingerprint: "00", commonName: "Demo", notBefore: .now, notAfter: .distantFuture), expiresIn: 3e7)
    }
    #endif

    // MARK: - Lifecycle

    func load() async {
        do {
            let loaded = try await store.load()
            assign(\.projects, loaded)
            // Read once, so every later `hostname(for:)` and `isConfigured` is a
            // pure read rather than a Keychain query from inside a view body.
            tunnelTargets.load(serviceIDs: loaded.flatMap(\.services).map(\.id))
            await refreshDetectedIcons()
        } catch {
            assign(\.lastError, error.localizedDescription)
        }

        await refreshSetup()
        await syncProxy()

        // Off the main actor's critical path: a broken rc file can make this
        // take the full timeout, and the project list should draw regardless.
        Task { [resolver] in
            let resolved = (try? await resolver.resolve()) ?? ShellEnvironmentResolver.fallback()
            await MainActor.run { self.adopt(resolved) }
        }
    }

    /// The runtime cannot exist until the shell environment is known, because a
    /// dev command launched with launchd's PATH would not find its own tooling.
    /// Re-reads helper and certificate state.
    ///
    /// Called on launch and whenever the app is brought forward, because the
    /// user approves the helper in System Settings, outside this process.
    func refreshSetup() async {
        await helperClient.refresh()
        await refreshTrust()
    }

    private func refreshTrust() async {
        guard helperClient.state.canServe else {
            assign(\.trust, .notGenerated)
            return
        }
        do {
            let pem = try await helperClient.exportRootCA()
            let host = trustProbeHost
            // Caddy only holds a certificate for a domain that is in its route
            // table, so before anything runs there is no leaf and the evaluation
            // falls back to the root on its own.
            let leaf = await ProxyLeafFetcher.leaf(for: host)
            assign(\.trust, try TrustEvaluator.evaluate(rootPEM: pem, issuedLeaf: leaf, host: host))
            if let pem { cacheRootForDevServers(pem) }
        } catch {
            assign(\.trust, .notGenerated)
            assign(\.lastError, error.localizedDescription)
        }
    }

    /// Node, Bun and Deno ignore the system trust store and read a PEM from a
    /// path, but the daemon keeps its own copy in a root-owned 0700 directory.
    /// This is the only copy a dev server can actually open.
    private func cacheRootForDevServers(_ pem: Data) {
        let destination = CaddyLayout.userReadableRoot
        guard (try? Data(contentsOf: destination)) != pem else { return }
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? pem.write(to: destination, options: .atomic)
    }

    /// Prefers a running service, because that is the only host the proxy has
    /// actually been asked to issue for.
    private var trustProbeHost: String {
        let running = projects
            .flatMap(\.services)
            .first { status(of: $0).isRunning }
        return running?.domain.value
            ?? projects.first?.services.first?.domain.value
            ?? "localfox.localhost"
    }

    // MARK: - Setup actions

    func installHelper() async {
        await helperClient.install()
        await finishSetupAction()
        Telemetry.send(.helperInstalled(helperOutcome))
    }

    /// The button the wall shows once the daemon is registered but silent.
    ///
    /// `install()` cannot fix that state: launchd answers `kSMErrorAlreadyRegistered`
    /// and keeps serving the sealed plist and the binary it already has. Only the
    /// unregister/register cycle replaces them.
    func reinstallHelper() async {
        await helperClient.reinstall()
        await finishSetupAction()
    }

    private var helperOutcome: Telemetry.HelperOutcome {
        if helperClient.lastError != nil { return .failure }
        return helperClient.state.canServe ? .ready : .needsApproval
    }

    /// Helper failures are reported on `helperClient.lastError`, which no view
    /// reads, so a registration that fails looks exactly like one that worked.
    ///
    /// Trust is installed here rather than behind a second button: by the time
    /// the helper answers, the user has already agreed to the privileged part,
    /// and a working helper with an untrusted CA still shows a browser warning.
    private func finishSetupAction() async {
        await refreshSetup()
        assign(\.lastError, helperClient.lastError)
        guard helperClient.state.canServe, trust.remedy == .install else { return }
        await installCertificate()
    }

    func openHelperApproval() {
        helperClient.openApproval()
    }

    func installCertificate() async {
        do {
            guard let pem = try await helperClient.exportRootCA() else {
                throw UserTrustStoreError.noRoot
            }
            try await UserTrustStore.install(pem: pem)
            Telemetry.send(.certificateTrusted(.success))
        } catch {
            assign(\.lastError, error.localizedDescription)
            Telemetry.send(.certificateTrusted(.failure))
        }
        await refreshTrust()
    }

    func repairCertificate() async {
        if case let .stale(installed, _) = trust {
            try? await UserTrustStore.remove(fingerprint: installed.fingerprint)
        }
        await installCertificate()
    }

    func removeCertificate() async {
        guard let identity = trust.identity else { return }
        do {
            try await UserTrustStore.remove(fingerprint: identity.fingerprint)
            Telemetry.send(.certificateUntrusted(.success))
        } catch {
            assign(\.lastError, error.localizedDescription)
            Telemetry.send(.certificateUntrusted(.failure))
        }
        await refreshTrust()
    }

    /// Reloads the request list for one service.
    ///
    /// Reads the whole tail once and filters by host, because one access log
    /// holds every route. Called on a timer only while a detail pane is open, so
    /// a dashboard nobody is looking at costs no XPC traffic.
    func refreshRequests(for service: Service) async {
        guard preferences.recordsRequests, helperClient.state.canServe else {
            assign(\.requests[service.id], nil)
            return
        }
        let host = service.domain.value
        guard let tail = try? await helperClient.accessLog(
            host: host, lines: Self.requestLimit
        ) else { return }
        // Parsed off the main actor. `AppState` is `@MainActor`, and decoding a
        // hundred JSON objects on the main thread every two seconds is a visible
        // hitch spent on a panel that is only ever read.
        let entries = await Task.detached {
            AccessLogEntry.parse(tail: tail, host: host, limit: Self.requestLimit)
        }.value
        assign(\.requests[service.id], entries.isEmpty ? nil : entries)
    }

    /// The helper already filters by host and returns only this many, so asking
    /// for more would be asking it to read further back for nothing.
    ///
    /// `nonisolated` so the detached parse can read it without hopping back.
    private nonisolated static let requestLimit = 100

    func requests(for service: Service) -> [AccessLogEntry] {
        requests[service.id] ?? []
    }

    /// Pushes the current service ports to the proxy. Only running services have
    /// a port, so a stopped one is simply absent from the table.
    func syncProxy() async {
        guard helperClient.state.canServe else { return }
        var routes: [ProxyRoute] = []
        for project in projects {
            for service in project.services {
                guard let port = status(of: service).port,
                      let route = ProxyRoute(
                          id: String(service.id.uuidString.prefix(8)),
                          domain: service.domain,
                          port: port
                      ) else { continue }
                routes.append(route)
            }
        }
        do {
            try await helperClient.setRoutes(routes, recordsRequests: preferences.recordsRequests)
        } catch {
            assign(\.lastError, error.localizedDescription)
        }
    }

    private func adopt(_ environment: ShellEnvironment) {
        assign(\.shellEnvironment, environment)
        guard runtime == nil else { return }
        runtime = ServiceRuntime(
            shell: environment,
            onStatus: { [weak self] id, status in
                Task { @MainActor in self?.setStatus(status, for: id) }
            },
            onLog: { [weak self] id in
                Task { @MainActor in await self?.refreshLog(for: id) }
            }
        )
        // Unlike the service runtime this needs no shell environment: the
        // binary is addressed by absolute path and runs with a minimal one. It
        // is built here anyway so the two share a lifetime and neither can be
        // nil while the other is not.
        tunnelRuntime = TunnelRuntime(
            onStatus: { [weak self] id, status in
                Task { @MainActor in self?.setTunnelStatus(status, for: id) }
            }
        )
        startRouteWatcher()
    }

    // MARK: - Running services

    func start(_ service: Service) async {
        guard let project = project(owning: service.id) else { return }
        switch service.kind {
        case .command:
            guard let runtime else { return }
            await runtime.start(service, projectName: project.name)
        case .portRoute:
            guard let routeWatcher, let port = service.portMode.fixedValue else { return }
            await routeWatcher.start(id: service.id, port: port)
        }
        Telemetry.send(.serviceStarted)
    }

    /// Closes the tunnel first, and waits for it.
    ///
    /// The reactive teardown in `setStatus` is a safety net, not the ordering:
    /// it fires from an unstructured task, so on its own the port can close
    /// while cloudflared is still queued behind a multi-second termination
    /// grace period, serving 502s under a URL somebody already has.
    func stop(_ service: Service) async {
        await unshare(service)
        switch service.kind {
        case .command: await runtime?.stop(service)
        case .portRoute: await routeWatcher?.stop(id: service.id)
        }
    }

    /// Same ordering as `stop`, and for a second reason: under Auto the new
    /// process can bind a different port, so a tunnel carried across a restart
    /// would point at the old one.
    func restart(_ service: Service) async {
        if service.kind == .portRoute {
            await stop(service)
            await start(service)
            return
        }
        guard let runtime, let project = project(owning: service.id) else { return }
        await unshare(service)
        await runtime.restart(service, projectName: project.name)
    }

    func startAll(_ project: Project) async {
        for service in project.services { await start(service) }
    }

    /// Concurrent, unlike `startAll`. Each service has its own process group, so
    /// nothing serialises them, and `terminate` escalates SIGINT to SIGKILL over
    /// six seconds for one unresponsive server. Sequentially that is six seconds
    /// per service with the interface waiting on all of them.
    func stopAll(_ project: Project) async {
        await withTaskGroup(of: Void.self) { group in
            for service in project.services {
                group.addTask { await self.stop(service) }
            }
        }
    }

    /// Called when the app is quitting, so neither a dev server nor a public
    /// URL outlives Localfox.
    ///
    /// Tunnels first. Stopping a service tears its tunnel down anyway, but only
    /// via the status callback, and that hop is not guaranteed to land before
    /// the process exits.
    func stopEverything() async {
        await tunnelRuntime?.stopAll()
        await routeWatcher?.stopAll()
        await runtime?.stopAll()
        await clearProxy()
    }

    func log(for service: Service) -> String {
        logs[service.id] ?? ""
    }

    private func refreshLog(for id: UUID) async {
        guard let runtime else { return }
        let text = await runtime.log(for: id)
        guard logs[id] != text else { return }
        logs[id] = text
    }

    func project(owning serviceID: UUID) -> Project? {
        projects.first { $0.services.contains { $0.id == serviceID } }
    }

    // MARK: - Status

    func status(of service: Service) -> ServiceStatus {
        statuses[service.id] ?? .stopped
    }

    var helper: HelperState { helperClient.state }

    /// The URL to open, which only exists once the proxy is actually serving.
    func url(for service: Service) -> URL? {
        guard helper.canServe else { return nil }
        return service.url
    }

    var runningCount: Int {
        statuses.values.count { $0.isRunning }
    }

    /// Localfox has no unprivileged fallback, so this gates the whole interface
    /// rather than degrading it.
    var needsSetup: Bool {
        !helper.canServe || !trust.isUsable
    }

    // MARK: - Editing

    func add(_ project: Project) {
        var updated = projects
        updated.append(project)
        save(updated)
        Telemetry.send(.projectAdded)
        Task { await refreshDetectedIcons() }
    }

    /// Stops first. Once the project is gone there is no row left to reach its
    /// processes from, and a dev server would outlive the interface that
    /// started it with no way to stop it short of quitting Localfox.
    func remove(projectID: UUID) async {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        await stopAll(project)
        save(projects.filter { $0.id != projectID })
        Telemetry.send(.projectRemoved)
        project.services.forEach(forget)
        await syncProxy()
    }

    /// Drops everything held for a service that no longer exists.
    func forget(_ service: Service) {
        assign(\.statuses[service.id], nil)
        assign(\.logs[service.id], nil)
        assign(\.tunnels[service.id], nil)
        assign(\.requests[service.id], nil)
        tunnelTargets.remove(for: service.id)
    }

    func replace(_ project: Project) {
        save(projects.map { $0.id == project.id ? project : $0 })
    }

    func setIcon(_ path: String?, for project: Project) async {
        var edited = project
        edited.iconPath = path.map { edited.iconPathValue(for: URL(fileURLWithPath: $0)) }
        await apply(edited)
    }

    // MARK: - Icons

    /// What `IconResolver` found for each project, which is deliberately not
    /// persisted: it is a fact about the directory, not a user choice, so a
    /// project that gains a favicon later picks it up on its own.
    private(set) var detectedIcons: [UUID: String] = [:]

    func iconPath(for project: Project) -> String? {
        project.iconURL?.path ?? detectedIcons[project.id]
    }

    func hasIconOverride(_ project: Project) -> Bool {
        project.iconPath != nil
    }

    func projectAssets(for project: Project) -> [ProjectAsset] {
        project.directory.map { ProjectAssetScanner().assets(root: $0, serviceDirectory: $0) } ?? []
    }

    /// Resolved off the main actor and written as one map, so a draw never
    /// touches the disk and an unchanged scan never triggers a redraw.
    ///
    /// Awaited rather than fired and forgotten: every caller is already async,
    /// and letting it land late makes the icon visibly pop in after the list has
    /// already drawn.
    func refreshDetectedIcons() async {
        let inputs = projects.compactMap { item in item.directory.map { (id: item.id, directory: $0) } }
        let resolved = await Task.detached {
            let resolver = IconResolver()
            return inputs.reduce(into: [UUID: String]()) { found, project in
                found[project.id] = resolver.projectIconPath(
                    root: project.directory,
                    serviceDirectory: project.directory
                )
            }
        }.value
        assign(\.detectedIcons, resolved)
    }

    /// Rejects a duplicate before writing, so the interface can show the clash
    /// against the domain field rather than after a failed save.
    ///
    /// Excludes a set, not one id: an edit sheet swapping two domains inside one
    /// project would otherwise clash against the sibling's saved value, which is
    /// about to be overwritten by the same save.
    func domainOwner(of domain: LocalDomain, excluding serviceIDs: Set<UUID>) -> Service? {
        for project in projects {
            for service in project.services
            where service.domain == domain && !serviceIDs.contains(service.id) {
                return service
            }
        }
        return nil
    }

    private func save(_ updated: [Project]) {
        let previous = projects
        assign(\.projects, updated)
        Task { [store] in
            do {
                try await store.save(updated)
            } catch {
                await MainActor.run {
                    self.assign(\.projects, previous)
                    self.assign(\.lastError, error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Observation

    /// Writes only when the value moved.
    ///
    /// `@Observable` notifies on an equal write too, so a blind assignment on a
    /// poll tick redraws every view that reads the property.
    private func assign<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<AppState, Value>,
        _ value: Value
    ) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }

    func setStatus(_ status: ServiceStatus, for serviceID: UUID) {
        guard statuses[serviceID] != status else { return }
        let wasRunning = statuses[serviceID]?.isRunning == true
        // A stop reported by the runtime lands here after the project it belongs
        // to was already removed, and would otherwise leave a status keyed to a
        // service nothing can show. Below the cheap check, because this scan is
        // linear over every service and the status usually has not moved.
        guard project(owning: serviceID) != nil else {
            statuses[serviceID] = nil
            tunnels[serviceID] = nil
            Task { await self.tunnelRuntime?.stop(serviceID) }
            return
        }
        statuses[serviceID] = status
        // A tunnel outliving the port it dials is the one failure this feature
        // must not have: cloudflared keeps serving 502s under a URL the user has
        // already sent to somebody. A restart counts, because the new process
        // can bind a different port under Auto.
        if wasRunning, !status.isRunning {
            // Cleared here as well as asked to stop. A tunnel that already
            // failed has no record left in the runtime, so `stop` returns
            // without reporting `.off`, and the stale failure would sit on a
            // stopped service until the next successful share.
            tunnels[serviceID] = nil
            Task { await self.tunnelRuntime?.stop(serviceID) }
        }
        // A newly discovered port is only useful once the proxy knows it.
        if status.isRunning || wasRunning || status == .stopped {
            Task { await self.syncProxy() }
        }
    }

    func setTunnelStatus(_ status: TunnelStatus, for serviceID: UUID) {
        // `.off` is the absence of a tunnel, so it is stored as one. Keeping the
        // case would leave every service ever shared in the map, and the menu
        // bar counts what is in it.
        let resolved: TunnelStatus? = status == .off ? nil : status
        // Compared before writing, and compared as the optional that is actually
        // stored. `dict[key] = nil` on an absent key still runs the setter, and
        // under @Observable that redraws every view reading `tunnels`.
        guard tunnels[serviceID] != resolved else { return }
        guard project(owning: serviceID) != nil else {
            tunnels[serviceID] = nil
            return
        }
        tunnels[serviceID] = resolved
    }

    /// The one write the sharing half of `AppState` needs from another file.
    ///
    /// A named operation rather than exposing `assign`, which is the write guard
    /// for the whole observable surface and has no business being callable on an
    /// arbitrary key path from anywhere in the app target.
    func report(_ error: String) {
        assign(\.lastError, error)
    }

    func clearError() {
        assign(\.lastError, nil)
    }
}
