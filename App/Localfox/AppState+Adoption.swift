import AppKit
import Foundation
import LocalfoxKit

/// Serving a domain from a server Localfox did not start.
///
/// A coding agent often runs `pnpm dev` in the project itself, and pressing
/// Start would run it twice. The route rides on `PortRouteWatcher`, so it is
/// watched and never owned: nothing here signals the process.
@MainActor
extension AppState {
    private enum Choice {
        case route, startAnother, cancel
    }

    func isAdopted(_ service: Service) -> Bool {
        adoptedServiceIDs.contains(service.id)
    }

    /// Stop or project removal can cancel a Start while the filesystem and socket scan is in flight.
    func startCommand(_ service: Service, projectName: String, runtime: ServiceRuntime) async {
        let lookup = Task { await existingServer(for: service, runtime: runtime) }
        pendingStarts[service.id] = lookup
        setStatus(.starting, for: service.id)
        let found = await lookup.value
        guard pendingStarts[service.id] == lookup else { return }
        let choice = found.map { ask(about: $0, for: service) } ?? .startAnother
        // A modal panel runs its own event loop. Check again before acting on its answer.
        guard pendingStarts[service.id] == lookup else { return }
        pendingStarts.removeValue(forKey: service.id)
        switch choice {
        case .route:
            guard let found, let routeWatcher else {
                setStatus(.stopped, for: service.id)
                return
            }
            adoptedServiceIDs.insert(service.id)
            await routeWatcher.start(id: service.id, port: found.port, family: found.family)
        case .startAnother:
            await runtime.start(service, projectName: projectName)
            Telemetry.send(.serviceStarted)
        case .cancel:
            setStatus(.stopped, for: service.id)
        }
    }

    private func existingServer(for service: Service, runtime: ServiceRuntime) async -> ExistingServer? {
        guard !isHeadlessRun, let directory = service.directory else { return nil }
        return await ExistingServerFinder().find(
            in: directory,
            excludingGroups: await runtime.ownedGroups(),
            excludingPorts: Set(statuses.values.compactMap(\.port)),
            excludingDirectories: worktreeDirectories(of: service),
            host: service.domain.value
        )
    }

    /// The route is gone and the process is untouched, whichever side ended it.
    func endAdoption(of id: UUID) async {
        adoptedServiceIDs.remove(id)
        await routeWatcher?.stop(id: id)
    }

    /// An adopted service goes back to stopped when its port stops answering,
    /// where a port route would wait for it. Nothing is left to wait on: the
    /// server was somebody else's, and it is not coming back under this row.
    func handle(_ event: PortRouteEvent) async {
        if case .waiting = event.status, adoptedServiceIDs.contains(event.id) {
            await endAdoption(of: event.id)
        } else {
            setStatus(event.status, for: event.id)
        }
    }

    /// An app-modal `NSAlert`, for the reason `ServiceRow.confirmsPublicShare`
    /// gives: this is reached from the menu bar popover.
    private func ask(about server: ExistingServer, for service: Service) -> Choice {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Already running on :\(server.port)"
        alert.informativeText = """
            \(server.executableName) (pid \(server.pid)) is serving \(service.name)'s folder. \
            Route \(service.domain.value) to it, or start another copy on a different port. \
            Localfox never stops a server it did not start.
            """
        alert.addButton(withTitle: "Route It")
        alert.addButton(withTitle: "Start Another Copy")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .route
        case .alertSecondButtonReturn: return .startAnother
        default: return .cancel
        }
    }
}
