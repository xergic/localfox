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

    private(set) var helper: HelperState = .notRegistered
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
        } catch {
            assign(\.lastError, error.localizedDescription)
        }

        // Off the main actor's critical path: a broken rc file can make this
        // take the full timeout, and the project list should draw regardless.
        Task { [resolver] in
            let resolved = (try? await resolver.resolve()) ?? ShellEnvironmentResolver.fallback()
            await MainActor.run { self.adopt(resolved) }
        }
    }

    /// The runtime cannot exist until the shell environment is known, because a
    /// dev command launched with launchd's PATH would not find its own tooling.
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

    func stopAll(_ project: Project) async {
        for service in project.services { await stop(service) }
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
    }

    func remove(projectID: UUID) {
        save(projects.filter { $0.id != projectID })
    }

    func replace(_ project: Project) {
        save(projects.map { $0.id == project.id ? project : $0 })
    }

    /// Rejects a duplicate before writing, so the interface can show the clash
    /// against the domain field rather than after a failed save.
    func domainOwner(of domain: LocalDomain, excluding serviceID: UUID?) -> Service? {
        for project in projects {
            for service in project.services
            where service.domain == domain && service.id != serviceID {
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
        statuses[serviceID] = status
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
