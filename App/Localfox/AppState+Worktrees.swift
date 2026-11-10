import Foundation
import LocalfoxKit

/// Git worktrees run as rows under their project, at their own domains.
///
/// Split off like `AppState+Routes.swift`, so the state file stays under the
/// lint limit.
@MainActor
extension AppState {
    /// Run when the popover or the dashboard comes forward, never on the status
    /// tick: an agent creates and removes worktrees while nobody is looking, and
    /// the list only matters to somebody who is.
    func refreshWorktrees() async {
        guard !worktrees.isDiscovering, !isHeadlessRun else { return }
        worktrees.isDiscovering = true
        defer { worktrees.isDiscovering = false }
        let inputs = projects.compactMap { project in project.directory.map { (id: project.id, directory: $0) } }
        let searchPath = shellEnvironment?.path ?? ProcessInfo.processInfo.environment["PATH"]
        worktrees.listings = await Task.detached { Worktrees.read(inputs, searchPath: searchPath) }.value
        rederiveWorktrees()
    }

    func rederiveWorktrees() {
        worktrees.rederive(projects: projects, isLive: isLive)
    }

    /// Every service the proxy, the lookups and the domain checks have to see,
    /// registered ones first.
    var allServices: [Service] {
        projects.flatMap(\.services) + worktrees.services
    }

    func service(id: UUID) -> Service? {
        projects.lazy.compactMap { $0.service(id: id) }.first ?? worktrees.checkout(containing: id)?.service(id: id)
    }

    /// The project a worktree service was derived from. It names the process in
    /// `LOCALFOX_PROJECT` and keeps `setStatus` from dropping the service.
    func worktreeParent(of serviceID: UUID) -> Project? {
        worktrees.checkout(containing: serviceID).flatMap { checkout in projects.first { $0.id == checkout.projectID } }
    }

    /// Every linked worktree, not only those with rows. A server an agent runs in
    /// a worktree nested inside the project is not the project's own.
    func worktreeDirectories(of service: Service) -> [URL] {
        guard let project = project(owning: service.id) else { return [] }
        return worktrees.listings[project.id]?.linked.map(\.directory) ?? []
    }

    /// A worktree with something running cannot be closed, so a running server
    /// is never out of sight.
    func showsRows(of checkout: WorktreeCheckout) -> Bool {
        worktrees.expanded.contains(checkout.id) || checkout.services.map(\.id).contains(where: isLive)
    }

    private func isLive(_ id: UUID) -> Bool {
        let status = statuses[id] ?? .stopped
        return status.isActive || status.isTransitioning
    }

    /// Projects and their worktrees narrowed by the popover's search. A parent
    /// that does not match keeps its heading when one of its worktrees does.
    func sections(matching query: String) -> [(project: Project, worktrees: [WorktreeCheckout])] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return orderedProjects.map { ($0, worktrees.checkouts(for: $0.id)) }
        }
        let port: (Service) -> Int? = { self.status(of: $0).port }
        let matched = Dictionary(
            orderedProjects.matching(query, port: port).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return orderedProjects.compactMap { project in
            let trees = worktrees.checkouts(for: project.id).compactMap { $0.matching(query, port: port) }
            if let shown = matched[project.id] { return (shown, trees) }
            guard !trees.isEmpty else { return nil }
            var heading = project
            heading.services = []
            return (heading, trees)
        }
    }
}
