import Darwin
import Foundation

/// The environment a dev command needs, recovered from the user's login shell.
///
/// A GUI app inherits launchd's environment, which carries a PATH of roughly
/// `/usr/bin:/bin:/usr/sbin:/sbin`. That finds none of `pnpm`, `bun`, `node`
/// under nvm/fnm/volta, or anything Homebrew installed, so a dev command that
/// works in Terminal fails with `command not found` when Localfox runs it.
public struct ShellEnvironment: Codable, Hashable, Sendable {
    public let shell: String
    public let path: String
    /// Everything else the shell exported that a toolchain might need, such as
    /// `NVM_DIR`, `VOLTA_HOME`, `PNPM_HOME`, `BUN_INSTALL`, `MISE_*`.
    public let variables: [String: String]
    public let capturedAt: Date
    /// Identifies the rc files this was captured from, so the cache can tell
    /// whether the user has edited their shell setup since.
    public let rcSignature: String

    public var pathEntries: [String] {
        path.split(separator: ":").map(String.init)
    }
}

public enum ShellEnvironmentError: Error, Equatable, Sendable, LocalizedError {
    case spawnFailed(errno: Int32)
    case timedOut(seconds: Int)
    case noSentinel(output: String)

    public var errorDescription: String? {
        switch self {
        case let .spawnFailed(code):
            "Could not start your login shell to read its environment (errno \(code))."
        case let .timedOut(seconds):
            """
            Your login shell did not respond within \(seconds) seconds. A shell \
            startup file is probably waiting for input. Localfox is using a \
            built-in PATH instead.
            """
        case .noSentinel:
            """
            Your login shell started but did not report its environment. Localfox \
            is using a built-in PATH instead.
            """
        }
    }
}

/// Probes the login shell once and caches the answer.
public struct ShellEnvironmentResolver: Sendable {
    /// Framed because an interactive shell prints message-of-the-day banners,
    /// powerlevel10k instant-prompt output and job-control warnings, none of
    /// which are environment.
    private static let begin = "\u{01}LOCALFOX_ENV_BEGIN\u{01}"
    private static let end = "\u{01}LOCALFOX_ENV_END\u{01}"

    /// Directories worth adding when the probe fails or the shell simply does
    /// not export them. Filtered to those that exist, so a missing tool never
    /// lengthens PATH for nothing.
    static let fallbackDirectories = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
        "~/.local/bin", "~/.bun/bin", "~/Library/pnpm", "~/.yarn/bin",
        "~/.volta/bin", "~/.local/share/mise/shims", "~/.asdf/shims", "~/.proto/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin"
    ]

    private static let rcFiles = [
        ".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile",
        ".config/fish/config.fish"
    ]

    public let timeout: Int
    public let cacheURL: URL

    public init(timeout: Int = 6, cacheURL: URL? = nil) {
        self.timeout = timeout
        self.cacheURL = cacheURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Localfox/shell-env.json")
    }

    /// The user's real login shell.
    ///
    /// Read from the password database rather than `$SHELL`, because launchd
    /// does not reliably set `SHELL` for a GUI process.
    public static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }

    public func cached() -> ShellEnvironment? {
        guard let data = try? Data(contentsOf: cacheURL),
              let stored = try? JSONDecoder().decode(ShellEnvironment.self, from: data),
              stored.rcSignature == Self.rcSignature()
        else { return nil }
        return stored
    }

    /// Returns the cached environment when the shell setup has not changed,
    /// otherwise probes again.
    public func resolve() async throws -> ShellEnvironment {
        if let cached = cached() { return cached }
        let resolved = try await probe()
        try? store(resolved)
        return resolved
    }

    public func store(_ environment: ShellEnvironment) throws {
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(environment).write(to: cacheURL, options: .atomic)
    }

    public func probe() async throws -> ShellEnvironment {
        let shell = Self.loginShell()
        let output = try await runProbe(shell: shell)
        let variables = try Self.parse(output)

        let path = Self.merge(
            path: variables["PATH"] ?? "",
            with: Self.existingFallbacks()
        )

        return ShellEnvironment(
            shell: shell,
            path: path,
            variables: variables.filter { $0.key != "PATH" },
            capturedAt: Date(),
            rcSignature: Self.rcSignature()
        )
    }

    /// The environment to fall back to when the probe fails, so a broken rc file
    /// degrades to "some commands are missing" rather than "nothing starts".
    public static func fallback() -> ShellEnvironment {
        ShellEnvironment(
            shell: loginShell(),
            path: existingFallbacks().joined(separator: ":"),
            variables: [:],
            capturedAt: Date(),
            rcSignature: rcSignature()
        )
    }

    // MARK: - Probe

    private func runProbe(shell: String) async throws -> String {
        // `-i` is not optional. Most people's PATH edits and every nvm shell
        // function live in .zshrc, which a login-only shell never sources.
        // `env -0` because a value may legitimately contain a newline.
        let script = """
        printf '%s' '\(Self.begin)'; /usr/bin/env -0; printf '%s' '\(Self.end)'
        """
        let arguments = shell.hasSuffix("fish")
            ? [shell, "-l", "-c", script]
            : [shell, "-l", "-i", "-c", script]

        var outputPipe: [Int32] = [0, 0]
        guard pipe(&outputPipe) == 0 else { throw ShellEnvironmentError.spawnFailed(errno: errno) }

        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)

        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own session, so a shell that hangs can be killed as a group
        // without the signal reaching Localfox itself.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        let status = posix_spawn(&pid, shell, &actions, &attributes, argv, environ)
        close(outputPipe[1])
        guard status == 0 else {
            close(outputPipe[0])
            throw ShellEnvironmentError.spawnFailed(errno: status)
        }

        let handle = FileHandle(fileDescriptor: outputPipe[0], closeOnDealloc: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))

        let reader = Task.detached { handle.readDataToEndOfFile() }
        // A `.zshrc` that blocks on a prompt must not hang app launch, so the
        // read races a wall clock and the shell is killed if it loses.
        let spawned = pid
        let limit = timeout
        let watchdog = Task.detached {
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return }
            kill(-spawned, SIGKILL)
        }

        let data = await reader.value
        watchdog.cancel()
        var reaped: Int32 = 0
        waitpid(pid, &reaped, 0)

        guard ContinuousClock.now < deadline || !data.isEmpty else {
            throw ShellEnvironmentError.timedOut(seconds: timeout)
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Parsing

    static func parse(_ output: String) throws -> [String: String] {
        guard let start = output.range(of: begin), let stop = output.range(of: end),
              start.upperBound <= stop.lowerBound else {
            throw ShellEnvironmentError.noSentinel(output: String(output.prefix(400)))
        }

        let body = output[start.upperBound..<stop.lowerBound]
        var variables: [String: String] = [:]
        for entry in body.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let split = entry.firstIndex(of: "=") else { continue }
            let name = String(entry[entry.startIndex..<split])
            guard !name.isEmpty else { continue }
            variables[name] = String(entry[entry.index(after: split)...])
        }
        return variables
    }

    /// Appends the fallback directories the shell did not already provide,
    /// preserving the shell's own ordering so a version manager's shim still
    /// wins over a Homebrew binary of the same name.
    static func merge(path: String, with extras: [String]) -> String {
        var seen: Set<String> = []
        var ordered: [String] = []
        for entry in path.split(separator: ":").map(String.init) + extras
        where isUsable(entry) && seen.insert(entry).inserted {
            ordered.append(entry)
        }
        return ordered.joined(separator: ":")
    }

    /// Real PATHs collect junk. A malformed rc file that writes
    /// `export PATH=$PATH:ANDROID_SDK_ROOT=/some/where` puts a literal
    /// `ANDROID_SDK_ROOT=/some/where` on PATH, which can never resolve, and an
    /// empty entry means "the current directory", which is a footgun when the
    /// working directory is someone's project. Only absolute paths survive.
    static func isUsable(_ entry: String) -> Bool {
        entry.hasPrefix("/")
    }

    static func existingFallbacks() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return fallbackDirectories
            .map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// A cheap fingerprint of every shell startup file. Size and modification
    /// date rather than contents, because this runs on every launch and the
    /// question is only "did anything change".
    static func rcSignature() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var parts: [String] = []
        for name in rcFiles {
            let url = home.appendingPathComponent(name)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? Int) ?? -1
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            parts.append("\(name):\(size):\(Int(modified))")
        }
        return parts.joined(separator: "|")
    }
}
