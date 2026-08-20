import Foundation
import Testing
@testable import LocalfoxKit

@Suite("parsing a login shell environment")
struct ShellEnvironmentParsingTests {
    private let begin = "\u{01}LOCALFOX_ENV_BEGIN\u{01}"
    private let end = "\u{01}LOCALFOX_ENV_END\u{01}"

    private func framed(_ pairs: [String]) -> String {
        "some motd noise\n" + begin + pairs.joined(separator: "\0") + "\0" + end + "\ntrailing junk"
    }

    @Test("variables between the sentinels are read")
    func readsFramedVariables() throws {
        let parsed = try ShellEnvironmentResolver.parse(framed(["PATH=/usr/bin:/bin", "HOME=/Users/me"]))
        #expect(parsed["PATH"] == "/usr/bin:/bin")
        #expect(parsed["HOME"] == "/Users/me")
    }

    /// An interactive shell prints a message of the day, powerlevel10k's
    /// instant prompt and job-control warnings. None of it is environment.
    @Test("noise outside the sentinels is discarded")
    func ignoresShellNoise() throws {
        let parsed = try ShellEnvironmentResolver.parse(framed(["A=1"]))
        #expect(parsed.count == 1)
        #expect(parsed["A"] == "1")
    }

    /// This is why the probe uses `env -0` rather than newline-separated output.
    @Test("a value containing a newline survives")
    func keepsEmbeddedNewlines() throws {
        let parsed = try ShellEnvironmentResolver.parse(framed(["SCRIPT=line one\nline two"]))
        #expect(parsed["SCRIPT"] == "line one\nline two")
    }

    @Test("a value containing an equals sign keeps all of it")
    func keepsEqualsInValue() throws {
        let parsed = try ShellEnvironmentResolver.parse(framed(["OPTS=--define=A=B"]))
        #expect(parsed["OPTS"] == "--define=A=B")
    }

    @Test("output with no sentinel is an error rather than an empty environment")
    func missingSentinelThrows() {
        #expect(throws: ShellEnvironmentError.self) {
            try ShellEnvironmentResolver.parse("zsh: command not found: something")
        }
    }

    @Test("an entry with no equals sign is skipped")
    func skipsMalformedEntries() throws {
        let parsed = try ShellEnvironmentResolver.parse(framed(["JUSTANAME", "B=2"]))
        #expect(parsed["B"] == "2")
        #expect(parsed.count == 1)
    }
}

@Suite("merging PATH")
struct ShellEnvironmentPathTests {
    @Test("the shell's own order is preserved so version manager shims still win")
    func preservesShellOrder() {
        let merged = ShellEnvironmentResolver.merge(
            path: "/Users/me/.volta/bin:/usr/bin",
            with: ["/opt/homebrew/bin"]
        )
        #expect(merged == "/Users/me/.volta/bin:/usr/bin:/opt/homebrew/bin")
    }

    @Test("a fallback the shell already provides is not added twice")
    func deduplicates() {
        let merged = ShellEnvironmentResolver.merge(
            path: "/opt/homebrew/bin:/usr/bin",
            with: ["/opt/homebrew/bin", "/bin"]
        )
        #expect(merged == "/opt/homebrew/bin:/usr/bin:/bin")
    }

    /// A real PATH found on this machine contained a literal
    /// `ANDROID_SDK_ROOT=/Users/ondra/Library/Android/sdk`, three times, put
    /// there by an rc file that wrote `export PATH=$PATH:ANDROID_SDK_ROOT=...`.
    /// It can never resolve, so it is dropped rather than carried into every
    /// spawned dev server.
    @Test("an entry that is not an absolute path is dropped")
    func dropsMalformedEntries() {
        let merged = ShellEnvironmentResolver.merge(
            path: "/usr/bin:ANDROID_SDK_ROOT=/Users/me/sdk:relative/bin",
            with: []
        )
        #expect(merged == "/usr/bin")
    }

    /// An empty PATH entry means the current working directory, which is a
    /// footgun when that directory is a project someone just cloned.
    @Test("an empty entry is dropped")
    func dropsEmptyEntries() {
        #expect(ShellEnvironmentResolver.merge(path: "/usr/bin::/bin", with: []) == "/usr/bin:/bin")
    }

    @Test("pathEntries splits what merge joined")
    func roundTrips() {
        let environment = ShellEnvironment(
            shell: "/bin/zsh", path: "/a:/b", variables: [:],
            capturedAt: Date(), rcSignature: "x"
        )
        #expect(environment.pathEntries == ["/a", "/b"])
    }
}

@Suite("the rc signature")
struct ShellEnvironmentSignatureTests {
    @Test("is stable across calls when nothing has changed")
    func isStable() {
        #expect(ShellEnvironmentResolver.rcSignature() == ShellEnvironmentResolver.rcSignature())
    }

    @Test("names every startup file it covers")
    func coversEveryStartupFile() {
        let signature = ShellEnvironmentResolver.rcSignature()
        for name in [".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile"] {
            #expect(signature.contains(name))
        }
    }
}

@Suite("probing the real login shell", .tags(.integration))
struct ShellEnvironmentProbeTests {
    /// The reason this component exists: a GUI-launched app sees roughly
    /// `/usr/bin:/bin:/usr/sbin:/sbin` and finds none of the user's toolchain.
    @Test("recovers a PATH longer than what launchd would hand a GUI app")
    func recoversRealPath() async throws {
        let resolved = try await ShellEnvironmentResolver(timeout: 10).probe()
        #expect(resolved.pathEntries.count > 4)
        #expect(resolved.shell.hasPrefix("/"))
        #expect(resolved.pathEntries.allSatisfy { $0.hasPrefix("/") })
    }

    @Test("the cache round-trips through disk")
    func cacheRoundTrips() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("localfox-tests-\(UUID().uuidString)/shell-env.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let resolver = ShellEnvironmentResolver(timeout: 10, cacheURL: url)
        #expect(resolver.cached() == nil)

        let probed = try await resolver.probe()
        try resolver.store(probed)
        #expect(resolver.cached() == probed)
    }
}

extension Tag {
    @Tag static var integration: Self
}
