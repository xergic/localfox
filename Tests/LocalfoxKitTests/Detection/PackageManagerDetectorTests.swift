import Foundation
import Testing
@testable import LocalfoxKit

@Suite("resolving package managers")
struct PackageManagerDetectorTests {
    @Test("each recognised lockfile selects its package manager", arguments: [
        ("pnpm-lock.yaml", PackageManager.pnpm),
        ("bun.lock", .bun),
        ("bun.lockb", .bun),
        ("yarn.lock", .yarn),
        ("package-lock.json", .npm)
    ])
    func resolvesLockfile(lockfile: String, expected: PackageManager) {
        let detector = PackageManagerDetector(fileSystem: InMemoryFileSystem(["/project/\(lockfile)": ""]))
        let result = detector.resolve(in: URL(fileURLWithPath: "/project", isDirectory: true))

        #expect(result.packageManager == expected)
        #expect(result.reason == lockfile)
    }

    @Test("the Corepack package manager field beats a conflicting lockfile")
    func packageManagerFieldWins() {
        let fileSystem = InMemoryFileSystem([
            "/project/package.json": #"{ "packageManager": "pnpm@9.15.0" }"#,
            "/project/yarn.lock": ""
        ])
        let directory = URL(fileURLWithPath: "/project", isDirectory: true)
        let result = PackageManagerDetector(fileSystem: fileSystem).resolve(in: directory)

        #expect(result.packageManager == .pnpm)
        #expect(result.reason == "packageManager: pnpm@9.15.0")
    }

    @Test("a workspace member inherits its lockfile from the monorepo root")
    func walksUpToWorkspaceLockfile() {
        let fileSystem = InMemoryFileSystem([
            "/workspace/pnpm-lock.yaml": "lockfileVersion: '9.0'",
            "/workspace/apps/web/package.json": #"{ "name": "web" }"#
        ])
        let directory = URL(fileURLWithPath: "/workspace/apps/web", isDirectory: true)
        let result = PackageManagerDetector(fileSystem: fileSystem).resolve(in: directory)

        #expect(result.packageManager == .pnpm)
        #expect(result.reason == "pnpm-lock.yaml")
    }

    @Test("the walk up stops at the filesystem root for a URL that came from the open panel")
    func stopsAtTheFilesystemRoot() {
        // NSOpenPanel hands back a bridged NSURL. Its deletingLastPathComponent
        // answers "/.." at the root instead of "/" again, so a walk that only
        // compares against its own parent never terminates.
        let panelURL = NSURL(fileURLWithPath: "/workspace/apps/web", isDirectory: true) as URL
        let chain = PackageManagerDetector().ancestors(of: panelURL)

        #expect(chain.map(\.path) == ["/workspace/apps/web", "/workspace/apps", "/workspace", "/"])
    }
}
