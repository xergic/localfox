import Foundation
import LocalfoxKit
import Observation
import os

/// Each registered project's git worktrees, as last discovered. Held in memory
/// only: a worktree is a fact about the repository, and a removed one has to
/// disappear without anything left in `projects.json` to clean up.
@MainActor
@Observable
final class Worktrees {
    struct Listing: Sendable {
        let projectPath: String
        let linked: [GitWorktree]
    }

    private(set) var checkouts: [UUID: [WorktreeCheckout]] = [:] {
        didSet { owners = Self.index(checkouts) }
    }
    /// Opened by hand. A worktree with something running shows its rows anyway.
    var expanded: Set<String> = []
    @ObservationIgnored var listings: [UUID: Listing] = [:]
    @ObservationIgnored var isDiscovering = false
    /// `setStatus` asks who owns a service on every change, so this is a lookup, not a scan.
    @ObservationIgnored private var owners: [UUID: WorktreeCheckout] = [:]

    func checkouts(for projectID: UUID) -> [WorktreeCheckout] {
        checkouts[projectID] ?? []
    }

    var services: [Service] {
        checkouts.values.joined().flatMap(\.services)
    }

    func checkout(containing serviceID: UUID) -> WorktreeCheckout? {
        owners[serviceID]
    }

    private static func index(_ checkouts: [UUID: [WorktreeCheckout]]) -> [UUID: WorktreeCheckout] {
        var owners: [UUID: WorktreeCheckout] = [:]
        for checkout in checkouts.values.joined() {
            for service in checkout.services { owners[service.id] = checkout }
        }
        return owners
    }

    /// Blocking: one `git` per project, run side by side so one slow repository
    /// does not hold up the rest. A worktree registered as a project of its own is
    /// left to that project, or its rows would appear twice.
    nonisolated static func read(_ projects: [(id: UUID, directory: URL)], searchPath: String?) -> [UUID: Listing] {
        guard let git = GitWorktreeReader.locateGit(searchPath: searchPath) else { return [:] }
        let reader = GitWorktreeReader(git: git)
        let resolved = projects.map { (id: $0.id, directory: $0.directory.resolvingSymlinksInPath()) }
        let registered = Set(resolved.map(\.directory.standardizedFileURL.path))
        let listings = OSAllocatedUnfairLock(initialState: [UUID: Listing]())
        DispatchQueue.concurrentPerform(iterations: resolved.count) { index in
            let project = resolved[index]
            guard let list = reader.list(in: project.directory),
                  let path = list.projectPath(for: project.directory) else { return }
            let linked = list.linked.filter { !registered.contains($0.directory.standardizedFileURL.path) }
            guard !linked.isEmpty else { return }
            listings.withLock { $0[project.id] = Listing(projectPath: path, linked: linked) }
        }
        return listings.withLock { $0 }
    }

    /// A live service keeps the value it was started with, domain included, even
    /// once its worktree is gone. The proxy routes it and Stop has to reach it
    /// until it stops, and the next discovery after that drops it.
    func rederive(projects: [Project], isLive: (UUID) -> Bool) {
        let live = checkouts.values.joined().compactMap { checkout -> WorktreeCheckout? in
            var kept = checkout
            kept.services = checkout.services.filter { isLive($0.id) }
            return kept.services.isEmpty ? nil : kept
        }
        var taken = Set(projects.flatMap(\.services).map(\.domain))
        let liveDomains = live.map { (id: $0.id, domains: Set($0.services.map(\.domain))) }
        var derived: [UUID: [WorktreeCheckout]] = [:]
        for project in projects {
            guard let listing = listings[project.id] else { continue }
            for worktree in listing.linked {
                // Its own live domains are not a clash, or a running worktree would
                // move to `-2` the next time the popover opened.
                let others = liveDomains
                    .filter { $0.id != worktree.directory.path }
                    .reduce(into: Set<LocalDomain>()) { $0.formUnion($1.domains) }
                guard let checkout = WorktreeServices.checkout(
                    of: project,
                    in: worktree,
                    projectPath: listing.projectPath,
                    taken: taken.union(others),
                    directoryExists: RealFileSystem().isDirectory
                ) else { continue }
                taken.formUnion(checkout.services.map(\.domain))
                derived[project.id, default: []].append(checkout)
            }
        }
        let projectIDs = Set(projects.map(\.id))
        for checkout in live where projectIDs.contains(checkout.projectID) {
            Self.keep(checkout, in: &derived[checkout.projectID, default: []])
        }
        guard derived != checkouts else { return }
        checkouts = derived
    }

    private static func keep(_ live: WorktreeCheckout, in checkouts: inout [WorktreeCheckout]) {
        guard let index = checkouts.firstIndex(where: { $0.id == live.id }) else {
            checkouts.append(live)
            return
        }
        for service in live.services {
            if let position = checkouts[index].services.firstIndex(where: { $0.id == service.id }) {
                checkouts[index].services[position] = service
            } else {
                checkouts[index].services.append(service)
            }
        }
    }

    #if DEBUG
    func adoptFixture(_ fixture: [UUID: [WorktreeCheckout]]) {
        checkouts = fixture
    }
    #endif
}
