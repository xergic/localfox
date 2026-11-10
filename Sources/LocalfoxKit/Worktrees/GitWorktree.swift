import Foundation

/// A linked git worktree, as `git worktree list --porcelain` reported it.
public struct GitWorktree: Hashable, Sendable {
    public let directory: URL
    /// The short branch name, nil for a detached HEAD.
    public let branch: String?

    public init(directory: URL, branch: String?) {
        self.directory = directory
        self.branch = branch
    }

    public var label: String { branch ?? directory.lastPathComponent }
}

/// The main checkout and the linked worktrees beside it.
public struct GitWorktreeList: Hashable, Sendable {
    public let main: URL
    public let linked: [GitWorktree]

    public init(main: URL, linked: [GitWorktree]) {
        self.main = main
        self.linked = linked
    }

    /// `directory` relative to the main checkout. nil when it lies outside it, or
    /// inside a linked worktree: a project registered at a worktree is a checkout
    /// the user picked, and the other worktrees are not its own.
    public func projectPath(for directory: URL) -> String? {
        guard let path = WorktreeServices.relativePath(of: directory, under: main) else { return nil }
        let isInsideLinked = linked.contains { WorktreeServices.relativePath(of: directory, under: $0.directory) != nil }
        return isInsideLinked ? nil : path
    }

    /// The first entry is always the main worktree. A `bare` entry has nothing to
    /// run, and a `prunable` one is a worktree whose directory git already knows
    /// is gone.
    public static func parse(_ porcelain: String) -> GitWorktreeList? {
        var main: URL?
        var linked: [GitWorktree] = []
        for block in porcelain.components(separatedBy: "\n\n") {
            var directory: URL?
            var branch: String?
            var isSkipped = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") {
                    directory = URL(fileURLWithPath: String(line.dropFirst("worktree ".count)), isDirectory: true)
                } else if line.hasPrefix("branch ") {
                    let ref = line.dropFirst("branch ".count)
                    branch = String(ref.hasPrefix("refs/heads/") ? ref.dropFirst("refs/heads/".count) : ref)
                } else if line == "bare" || line == "prunable" || line.hasPrefix("prunable ") {
                    isSkipped = true
                }
            }
            guard let directory else { continue }
            if main == nil {
                main = directory
            } else if !isSkipped {
                linked.append(GitWorktree(directory: directory, branch: branch))
            }
        }
        return main.map { GitWorktreeList(main: $0, linked: linked) }
    }
}
