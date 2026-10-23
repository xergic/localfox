import Foundation
import LocalfoxKit

@MainActor
extension AppState {
    /// Pinned projects first, each part in the order the projects were added.
    /// Both lists and the popover's arrow keys walk this one order.
    var orderedProjects: [Project] {
        let pinned = preferences.pinnedProjectIDs
        guard !pinned.isEmpty else { return projects }
        return projects.filter { pinned.contains($0.id) } + projects.filter { !pinned.contains($0.id) }
    }

    func isPinned(_ project: Project) -> Bool {
        preferences.pinnedProjectIDs.contains(project.id)
    }

    func togglePin(_ project: Project) {
        if isPinned(project) {
            preferences.pinnedProjectIDs.remove(project.id)
        } else {
            preferences.pinnedProjectIDs.insert(project.id)
        }
    }
}
