import Foundation
import Testing

@testable import LocalfoxKit

@Suite("reading git worktrees")
struct GitWorktreeTests {
    private let porcelain = """
        worktree /Users/me/wishfox
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /Users/me/wishfox/.claude/worktrees/fix-cart
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/fix/cart

        worktree /Users/me/wishfox-review
        HEAD 3333333333333333333333333333333333333333
        detached

        worktree /Users/me/gone
        HEAD 4444444444444444444444444444444444444444
        branch refs/heads/gone
        prunable gitdir file points to non-existent location

        worktree /Users/me/bare.git
        bare

        worktree /Users/me/locked
        HEAD 5555555555555555555555555555555555555555
        branch refs/heads/locked
        locked

        """

    @Test("the first entry is the main checkout and is not listed as linked")
    func mainEntryIsSkipped() throws {
        let list = try #require(GitWorktreeList.parse(porcelain))
        #expect(list.main.path == "/Users/me/wishfox")
        #expect(!list.linked.contains { $0.directory.path == "/Users/me/wishfox" })
    }

    @Test("a branch is labelled by its short name, slashes included")
    func branchLabel() throws {
        let list = try #require(GitWorktreeList.parse(porcelain))
        let worktree = try #require(list.linked.first)
        #expect(worktree.branch == "fix/cart")
        #expect(worktree.label == "fix/cart")
    }

    @Test("a detached worktree is labelled by its folder")
    func detachedLabel() throws {
        let list = try #require(GitWorktreeList.parse(porcelain))
        let worktree = try #require(list.linked.first { $0.directory.path == "/Users/me/wishfox-review" })
        #expect(worktree.branch == nil)
        #expect(worktree.label == "wishfox-review")
    }

    @Test("prunable and bare entries are skipped, a locked one is kept")
    func prunableAndBareAreSkipped() throws {
        let list = try #require(GitWorktreeList.parse(porcelain))
        #expect(list.linked.map(\.directory.lastPathComponent) == ["fix-cart", "wishfox-review", "locked"])
    }

    @Test("a project's path is relative to the main checkout, and a project at a worktree has none")
    func projectPath() throws {
        let list = try #require(GitWorktreeList.parse(porcelain))
        #expect(list.projectPath(for: URL(fileURLWithPath: "/Users/me/wishfox")) == "")
        #expect(list.projectPath(for: URL(fileURLWithPath: "/Users/me/wishfox/frontend")) == "frontend")
        #expect(list.projectPath(for: URL(fileURLWithPath: "/Users/me/wishfox/.claude/worktrees/fix-cart")) == nil)
        #expect(list.projectPath(for: URL(fileURLWithPath: "/Users/me/other")) == nil)
    }

    @Test("empty output is no repository")
    func emptyOutput() {
        #expect(GitWorktreeList.parse("") == nil)
    }

    @Test("a real repository lists a real worktree, and a missing directory is dropped")
    func readsARealRepository() throws {
        guard let git = GitWorktreeReader.locateGit(searchPath: ProcessInfo.processInfo.environment["PATH"]) else { return }
        let tree = TempTree()
        defer { tree.cleanUp() }
        let repo = tree.makeDirectory("repo")
        func run(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = git
            process.arguments = ["-C", repo.path, "-c", "user.name=t", "-c", "user.email=t@t"] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        try run(["init", "-q"])
        try run(["commit", "-q", "--allow-empty", "-m", "init"])
        try run(["worktree", "add", "-q", "-b", "fix/cart", tree.root.appendingPathComponent("wt").path])
        try run(["worktree", "add", "-q", "-b", "doomed", tree.root.appendingPathComponent("doomed").path])
        try FileManager.default.removeItem(at: tree.root.appendingPathComponent("doomed"))

        let list = try #require(GitWorktreeReader(git: git).list(in: repo))
        #expect(list.main.resolvingSymlinksInPath().path == repo.path)
        #expect(list.linked.map(\.label) == ["fix/cart"])
    }

    @Test("a directory that is not a repository has no worktrees")
    func notARepository() {
        guard let git = GitWorktreeReader.locateGit(searchPath: ProcessInfo.processInfo.environment["PATH"]) else { return }
        let tree = TempTree()
        defer { tree.cleanUp() }
        #expect(GitWorktreeReader(git: git).list(in: tree.root) == nil)
    }
}
