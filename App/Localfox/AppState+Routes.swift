import Foundation
import LocalfoxKit

/// The port route half of `AppState`, and the edits that had to move with it.
///
/// Split off like `AppState+Sharing.swift`, so the state file stays under the
/// lint limit.
@MainActor
extension AppState {
    /// A signed build's helper accepts these runs, so a table they sent or cleared
    /// would replace the real app's.
    var isHeadlessRun: Bool {
        SnapshotRenderer.request != nil || CommandLine.arguments.contains("--verify-runtime")
    }

    /// One consumer loop, so events reach `setStatus` in the order the watcher
    /// made them. The task inherits the main actor, so there is no hop per event.
    func startRouteWatcher() {
        let watcher = PortRouteWatcher()
        routeWatcher = watcher
        Task { [weak self] in
            for await event in watcher.events {
                self?.setStatus(event.status, for: event.id)
            }
        }
    }

    /// Awaited, unlike the sync `setStatus` schedules, because the app exits
    /// right after this returns.
    ///
    /// A route's server keeps running after Localfox quits, so a route left in
    /// Caddy's table would keep serving the domain with nothing on screen to
    /// stop it.
    func clearProxy() async {
        guard helperClient.state.canServe, !isHeadlessRun else { return }
        do {
            try await helperClient.setRoutes([], recordsRequests: preferences.recordsRequests)
        } catch {
            report(error.localizedDescription)
        }
    }

    /// Applies an edited project and reports which running services now hold a
    /// domain their process does not know about.
    ///
    /// The proxy is synced before anything restarts, so the route table already
    /// carries the new host by the time a process comes back and confirms over it.
    @discardableResult
    func apply(_ edited: Project) async -> [Service] {
        let previous = projects.first { $0.id == edited.id }
        // Stopped before the save, for the reason `remove(projectID:)` gives:
        // once the row is gone nothing can reach the watch or the process.
        let removed = previous?.services.filter { edited.service(id: $0.id) == nil } ?? []
        for service in removed { await stop(service) }
        let moved = edited.services.filter { service in
            service.kind == .command
                && previous?.service(id: service.id)?.domain != service.domain
                && status(of: service).isRunning
        }
        // A route's watch holds the port it started with. Asked of the watcher,
        // not of `status`, which still reads `.starting` or a stale value while
        // the first probe or an event is in flight.
        var repointed: [Service] = []
        for service in edited.services
        where service.kind == .portRoute && previous?.service(id: service.id)?.portMode != service.portMode {
            if await routeWatcher?.isWatching(service.id) == true { repointed.append(service) }
        }
        replace(edited)
        removed.forEach(forget)
        for route in repointed { await restart(route) }
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
}
