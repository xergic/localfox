import Darwin
import Foundation

public struct SpawnRequest: Sendable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: URL
    public var environment: [String: String]

    public init(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    /// Runs a dev command the way the user's terminal would.
    ///
    /// Through the login shell, in the service directory, because `mise`, `asdf`
    /// and `.nvmrc` all resolve per directory and a single captured PATH gets
    /// them wrong. `exec` replaces the shell rather than leaving it as an extra
    /// frame between Localfox and the dev server.
    public static func devCommand(
        _ command: String,
        in directory: URL,
        shell: String,
        environment: [String: String]
    ) -> SpawnRequest {
        SpawnRequest(
            executable: shell,
            arguments: [shell, "-l", "-i", "-c", "exec \(command)"],
            workingDirectory: directory,
            environment: environment
        )
    }
}

public enum SpawnError: Error, Equatable, Sendable, LocalizedError {
    case pipeFailed(errno: Int32)
    case spawnFailed(errno: Int32, executable: String)

    public var errorDescription: String? {
        switch self {
        case let .pipeFailed(code):
            "Could not create a pipe for the process output (errno \(code))."
        case let .spawnFailed(code, executable):
            "Could not start \(executable) (errno \(code): \(String(cString: strerror(code))))."
        }
    }
}

/// A process Localfox started, and the group that contains its whole tree.
public struct SpawnedProcess: Sendable {
    public let pid: pid_t
    /// Equal to `pid`, because `POSIX_SPAWN_SETSID` makes the child a session
    /// and group leader. Signalling this group is what reaches a dev server's
    /// descendants even after the launcher execs away and they reparent to
    /// launchd.
    public let processGroup: pid_t
    public let startedAt: Date
    public let standardOutput: FileHandle
    public let standardError: FileHandle

    /// Guards against a recycled pid. `kill(pid, 0)` proves only that some
    /// process occupies the number, never that it is still the same one.
    public var identity: String { "\(pid)-\(Int(startedAt.timeIntervalSince1970))" }
}

public enum ProcessSpawner {
    /// Starts a command in its own session.
    ///
    /// `Foundation.Process` cannot do this: it offers no way to create a session
    /// or process group, so `pnpm dev` -> `node` -> `next-server` escapes
    /// `terminate()` and leaves an orphan holding the port. That orphan is the
    /// exact failure this product exists to remove. There is no `/usr/bin/setsid`
    /// on macOS, so it has to happen at spawn time.
    public static func spawn(_ request: SpawnRequest) throws -> SpawnedProcess {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw SpawnError.pipeFailed(errno: errno) }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw SpawnError.pipeFailed(errno: errno)
        }

        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        // Rather than a `cd &&` prefix, which would need shell quoting and
        // races a concurrent chdir in this process.
        posix_spawn_file_actions_addchdir_np(&actions, request.workingDirectory.path)

        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        let argv: [UnsafeMutablePointer<CChar>?] = request.arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] =
            request.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, request.executable, &actions, &attributes, argv, envp)

        close(outPipe[1])
        close(errPipe[1])

        guard status == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            throw SpawnError.spawnFailed(errno: status, executable: request.executable)
        }

        return SpawnedProcess(
            pid: pid,
            processGroup: pid,
            startedAt: Date(),
            standardOutput: FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true),
            standardError: FileHandle(fileDescriptor: errPipe[0], closeOnDealloc: true)
        )
    }

    public enum Outcome: Equatable, Sendable {
        case exited
        case killed
        case alreadyGone
        case refused(reason: String)
    }

    /// Stops the whole tree, escalating only as far as it has to.
    ///
    /// SIGINT first because Vite and Next unbind their ports and clean up on it,
    /// where SIGKILL leaves a stale `.next` lock behind that breaks the next run.
    public static func terminate(
        group: pid_t,
        interruptGrace: Duration = .milliseconds(1500),
        terminateGrace: Duration = .seconds(3)
    ) async -> Outcome {
        // Localfox created this group with SETSID, so the group id is its own
        // child's pid and can never be the shell that launched Localfox.
        guard group > 1 else { return .refused(reason: "not a process group Localfox owns") }
        guard group != getpgrp() else { return .refused(reason: "Localfox's own process group") }
        guard isAlive(group) else { return .alreadyGone }

        kill(-group, SIGINT)
        if await waitForExit(group, within: interruptGrace) { return .exited }

        kill(-group, SIGTERM)
        if await waitForExit(group, within: terminateGrace) { return .exited }

        kill(-group, SIGKILL)
        _ = await waitForExit(group, within: .seconds(2))
        return .killed
    }

    public static func isAlive(_ group: pid_t) -> Bool {
        // Signal 0 checks for the group's existence without delivering anything.
        // ESRCH means gone; EPERM means it exists but belongs to someone else.
        kill(-group, 0) == 0 || errno == EPERM
    }

    private static func waitForExit(_ group: pid_t, within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            // Reap the direct child so it does not linger as a zombie, which
            // would keep answering signal 0 forever.
            var ignored: Int32 = 0
            _ = waitpid(group, &ignored, WNOHANG)
            if !isAlive(group) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !isAlive(group)
    }
}
