import Foundation
import os

/// Runs `git worktree list --porcelain`. Any failure reads as no worktrees: a
/// project that is not a repository is the common case, not an error.
public struct GitWorktreeReader: Sendable {
    public let git: URL
    public let timeout: Duration

    public init(git: URL, timeout: Duration = .seconds(3)) {
        self.git = git
        self.timeout = timeout
    }

    /// `/usr/bin/git` is a shim that pops the Command Line Tools installer when
    /// no developer directory is selected, so it is used only once one is.
    public static func locateGit(searchPath: String?, fileManager: FileManager = .default) -> URL? {
        let directories = (searchPath ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        for directory in directories where directory != "/usr/bin" {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("git")
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        let developerDirectories = ["/Library/Developer/CommandLineTools/usr/bin/git", "/var/db/xcode_select_link"]
        guard developerDirectories.contains(where: fileManager.fileExists(atPath:)) else { return nil }
        return URL(fileURLWithPath: "/usr/bin/git")
    }

    /// Blocks for as long as git runs, at most `timeout`. Drops linked worktrees
    /// whose directory is gone but not yet marked prunable.
    public func list(in directory: URL, fileSystem: some FileSystemReading = RealFileSystem()) -> GitWorktreeList? {
        guard let output = run(in: directory), let list = GitWorktreeList.parse(output) else { return nil }
        return GitWorktreeList(main: list.main, linked: list.linked.filter { fileSystem.isDirectory($0.directory) })
    }

    private func run(in directory: URL) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = git
        process.arguments = ["-C", directory.path, "worktree", "list", "--porcelain"]
        var environment = ProcessInfo.processInfo.environment
        // A read must never take the index lock from an agent committing in the same repository.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // The flag is what keeps the watchdog from signalling a pid that has already
        // been reaped and handed to somebody else.
        let finished = OSAllocatedUnfairLock(initialState: false)
        let pid = process.processIdentifier
        let watchdog = DispatchWorkItem {
            finished.withLock { done in if !done { kill(pid, SIGKILL) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        finished.withLock { $0 = true }
        watchdog.cancel()
        process.waitUntilExit()

        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
