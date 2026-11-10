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

    /// True when Start is settled here, because the user routed to the running
    /// server or backed out. False means start a copy as usual.
    ///
    /// Skips a service that is running or already starting, because `startAll`
    /// calls `start` for every service in the project.
    func routesToExistingServer(_ service: Service) async -> Bool {
        let before = status(of: service)
        guard !isHeadlessRun, !before.isActive, !before.isTransitioning, let directory = service.directory else {
            return false
        }
        // Held for the lookup so a second click cannot ask twice.
        setStatus(.starting, for: service.id)
        let found = await ExistingServerFinder().find(
            in: directory,
            excludingGroups: await runtime?.ownedGroups() ?? [],
            excludingPorts: Set(statuses.values.compactMap(\.port))
        )
        guard let found else { return false }
        switch ask(about: found, for: service) {
        case .route:
            adoptedServiceIDs.insert(service.id)
            await routeWatcher?.start(id: service.id, port: found.port)
        case .startAnother:
            return false
        case .cancel:
            setStatus(before, for: service.id)
        }
        return true
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
