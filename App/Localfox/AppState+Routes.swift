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
        let diagnostics = ["--verify-runtime", "--verify-proxy", "--verify-helper", "--install-helper", "--uninstall-helper"]
        return SnapshotRenderer.request != nil || CommandLine.arguments.contains(where: diagnostics.contains)
    }

    /// One consumer loop, so events reach `setStatus` in the order the watcher
    /// made them. The task inherits the main actor, so there is no hop per event.
    ///
    /// Started from `load()`, not from the shell probe, which can take its full
    /// timeout and a route needs no shell. Once only, since `load()` can rerun.
    func startRouteWatcher() {
        guard routeWatcher == nil else { return }
        let watcher = PortRouteWatcher()
        routeWatcher = watcher
        Task { [weak self] in
            for await event in watcher.events {
                await self?.handle(event)
            }
        }
    }

    /// Applies an edited project and reports which running services now hold a
    /// domain their process does not know about.
    ///
    /// The proxy is synced before anything restarts, so the route table already
    /// carries the new host by the time a process comes back and confirms over it.
    @discardableResult
    func apply(
        _ edited: Project, replacing previous: Project, sharingChanges: [TunnelTargets.Change] = []
    ) async throws -> [Service] {
        let removed = previous.services.filter { edited.service(id: $0.id) == nil }
        let moved = edited.services.filter { service in
            service.kind == .command
                && !isAdopted(service)
                && previous.service(id: service.id).map { $0.domain != service.domain || $0.portMode != service.portMode } == true
                && status(of: service).isRunning
        }
        // A route's watch holds the port it started with. Asked of the watcher,
        // not of `status`, which still reads `.starting` or a stale value while
        // the first probe or an event is in flight.
        var repointed: [Service] = []
        for service in edited.services
        where service.kind == .portRoute && previous.service(id: service.id)?.portMode != service.portMode {
            if await routeWatcher?.isWatching(service.id) == true { repointed.append(service) }
        }
        let warning = try await tunnelTargets.saving(sharingChanges, removing: removed.map(\.id)) {
            try await persist(id: edited.id, from: previous, to: edited)
        }
        if let warning { report(warning) }
        for service in removed { await stop(service) }
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
