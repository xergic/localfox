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

    /// Owns registration and the XPC channel. Read through `helper`.
    let helperClient = HelperClient()
    private(set) var trust: RootCAStatus = .notGenerated
    private(set) var shellEnvironment: ShellEnvironment?
    private(set) var lastError: String?

    private(set) var logs: [UUID: String] = [:]

    private let store: ProjectStore
    private let resolver = ShellEnvironmentResolver()
    private var runtime: ServiceRuntime?

    init(store: ProjectStore = ProjectStore()) {
        self.store = store
    }

    // MARK: - Lifecycle

    func load() async {
        do {
            let loaded = try await store.load()
            assign(\.projects, loaded)
            await refreshDetectedIcons()
        } catch {
            assign(\.lastError, error.localizedDescription)
        }

        await refreshSetup()

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
            try await helperClient.installRootCATrust()
        } catch {
            assign(\.lastError, error.localizedDescription)
        }
        await refreshTrust()
    }

    func repairCertificate() async {
        if case let .stale(installed, _) = trust {
            try? await helperClient.removeRootCATrust(sha256Hex: installed.fingerprint)
        }
        await installCertificate()
    }

    func removeCertificate() async {
        guard let identity = trust.identity else { return }
        do {
            try await helperClient.removeRootCATrust(sha256Hex: identity.fingerprint)
        } catch {
            assign(\.lastError, error.localizedDescription)
        }
        await refreshTrust()
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
            try await helperClient.setRoutes(routes)
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
    }

    // MARK: - Running services

    func start(_ service: Service) async {
        guard let runtime, let project = project(owning: service.id) else { return }
        await runtime.start(service, projectName: project.name)
    }

    func stop(_ service: Service) async {
        await runtime?.stop(service)
    }

    func restart(_ service: Service) async {
        guard let runtime, let project = project(owning: service.id) else { return }
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

    /// Called when the app is quitting, so no dev server outlives Localfox.
    func stopEverything() async {
        await runtime?.stopAll()
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
        Task { await refreshDetectedIcons() }
    }

    /// Stops first. Once the project is gone there is no row left to reach its
    /// processes from, and a dev server would outlive the interface that
    /// started it with no way to stop it short of quitting Localfox.
    func remove(projectID: UUID) async {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        await stopAll(project)
        save(projects.filter { $0.id != projectID })
        for service in project.services {
            statuses[service.id] = nil
            logs[service.id] = nil
        }
        await syncProxy()
    }

    func replace(_ project: Project) {
        save(projects.map { $0.id == project.id ? project : $0 })
    }

    /// Applies an edited project and reports which running services now hold a
    /// domain their process does not know about.
    ///
    /// The proxy is synced before anything restarts, so the route table already
    /// carries the new host by the time a process comes back and confirms over it.
    @discardableResult
    func apply(_ edited: Project) async -> [Service] {
        let previous = projects.first { $0.id == edited.id }
        let moved = edited.services.filter { service in
            previous?.service(id: service.id)?.domain != service.domain
                && status(of: service).isRunning
        }
        replace(edited)
        await refreshDetectedIcons()
        await syncProxy()
        return moved
    }

    /// `LOCALFOX_URL` and `LOCALFOX_HOST` are injected at spawn, so a running
    /// service cannot pick up a new domain without being restarted. Reads the
    /// service back from the store first: restarting the stale value would
    /// re-inject the old host, which is the whole bug.
    func restartForNewDomain(_ services: [Service]) async {
        for service in services {
            guard let current = projects.compactMap({ $0.service(id: service.id) }).first else { continue }
            await restart(current)
        }
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
        ProjectAssetScanner().assets(root: project.directory, serviceDirectory: project.directory)
    }

    /// Resolved off the main actor and written as one map, so a draw never
    /// touches the disk and an unchanged scan never triggers a redraw.
    ///
    /// Awaited rather than fired and forgotten: every caller is already async,
    /// and letting it land late makes the icon visibly pop in after the list has
    /// already drawn.
    private func refreshDetectedIcons() async {
        let inputs = projects.map { (id: $0.id, directory: $0.directory) }
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
        // A stop reported by the runtime lands here after the project it belongs
        // to was already removed, and would otherwise leave a status keyed to a
        // service nothing can show. Below the cheap check, because this scan is
        // linear over every service and the status usually has not moved.
        guard project(owning: serviceID) != nil else {
            statuses[serviceID] = nil
            return
        }
        statuses[serviceID] = status
        // A newly discovered port is only useful once the proxy knows it.
        if status.isRunning || status == .stopped {
            Task { await self.syncProxy() }
        }
    }

    func clearError() {
        assign(\.lastError, nil)
    }
}

extension ServiceStatus {
    /// Uses the existing palette rather than inventing an indicator: Portfox has
    /// no running/stopped dot because it only ever lists running things.
    var tint: Color {
        switch self {
        case .running: Theme.success
        case .starting, .stopping: Theme.accent
        case .failed: Theme.danger
        case .stopped: Theme.secondaryText
        }
    }

    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case let .running(_, port): ":\(port)"
        case .stopping: "Stopping"
        case .failed: "Failed"
        }
    }
}
