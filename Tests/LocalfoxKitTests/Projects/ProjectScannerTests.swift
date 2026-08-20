import Foundation
import Testing
@testable import LocalfoxKit

private func scan(_ tree: [String: String], at path: String = "/w") throws -> ProjectScan {
    try ProjectScanner(fileSystem: InMemoryFileSystem(tree))
        .scan(directory: URL(fileURLWithPath: path, isDirectory: true))
}

private let monorepo: [String: String] = [
    "/w/package.json": #"{"name":"wishfox","private":true}"#,
    "/w/pnpm-lock.yaml": "lockfileVersion: '9.0'",
    "/w/pnpm-workspace.yaml": "packages:\n  - \"apps/*\"\n  - \"packages/*\"\n",
    "/w/apps/web/package.json": #"{"name":"@wishfox/web","dependencies":{"next":"15.1.0"},"scripts":{"dev":"next dev"}}"#,
    "/w/apps/web/next.config.js": "",
    "/w/apps/api/package.json": #"{"name":"@wishfox/api","dependencies":{"express":"5"},"scripts":{"dev":"node index.js"}}"#,
    "/w/apps/admin/package.json": #"{"name":"@wishfox/admin","devDependencies":{"vite":"6"},"scripts":{"dev":"vite"}}"#,
    "/w/apps/admin/vite.config.ts": "",
    // No development script, so it is a library rather than a service.
    "/w/packages/ui/package.json": #"{"name":"@wishfox/ui","scripts":{"build":"tsc"}}"#
]

@Suite("scanning a project directory")
struct ProjectScannerTests {
    @Test("a single package offers one service on the project's own domain")
    func singlePackage() throws {
        let result = try scan([
            "/w/package.json": #"{"name":"wishfox","dependencies":{"next":"15"},"scripts":{"dev":"next dev"}}"#,
            "/w/next.config.js": "",
            "/w/pnpm-lock.yaml": ""
        ])
        #expect(result.candidates.count == 1)
        #expect(result.candidates[0].framework == .nextJS)
        #expect(result.candidates[0].domain.value == "wishfox.localhost")
        #expect(result.candidates[0].isApex)
        #expect(result.candidates[0].command == "pnpm dev")
    }

    @Test("a workspace is recognised as one")
    func detectsWorkspace() throws {
        #expect(try scan(monorepo).isWorkspace)
    }

    /// The rule that stops a monorepo offering fourteen services when three of
    /// them are runnable.
    @Test("a package with no development script is not offered")
    func skipsLibraries() throws {
        let names = try scan(monorepo).candidates.map(\.name)
        #expect(!names.contains("Ui"))
        #expect(names.count == 3)
    }

    @Test("the web app takes the apex domain and the rest take subdomains")
    func assignsDomains() throws {
        let byName = Dictionary(uniqueKeysWithValues: try scan(monorepo).candidates.map { ($0.name, $0) })
        #expect(byName["Web"]?.domain.value == "wishfox.localhost")
        #expect(byName["Web"]?.isApex == true)
        #expect(byName["API"]?.domain.value == "api.wishfox.localhost")
        #expect(byName["Admin"]?.domain.value == "admin.wishfox.localhost")
    }

    @Test("exactly one candidate is the apex")
    func oneApex() throws {
        #expect(try scan(monorepo).candidates.count(where: \.isApex) == 1)
    }

    @Test("the apex and the well-known services are ticked by default")
    func defaultSelection() throws {
        let selected = try scan(monorepo).candidates.filter(\.isSelected).map(\.name).sorted()
        #expect(selected == ["API", "Admin", "Web"])
    }

    @Test("every offered domain is unique, which the store also enforces")
    func domainsAreUnique() throws {
        let domains = try scan(monorepo).candidates.map(\.domain.value)
        #expect(Set(domains).count == domains.count)
    }

    /// A member directory has no lockfile of its own, so a resolver that does not
    /// walk up reports npm and produces a command that does not work.
    @Test("the package manager comes from the workspace root")
    func inheritsPackageManager() throws {
        #expect(try scan(monorepo).packageManager.packageManager == .pnpm)
    }

    @Test("a directory with no development script reports a warning rather than nothing")
    func warnsWhenNothingRunnable() throws {
        let result = try scan(["/w/package.json": #"{"name":"empty","scripts":{"build":"tsc"}}"#])
        #expect(result.candidates.isEmpty)
        #expect(!result.warnings.isEmpty)
    }

    @Test("api is title-cased as an acronym")
    func namesAcronyms() {
        #expect(ProjectScanner.displayName("api") == "API")
        #expect(ProjectScanner.displayName("web") == "Web")
    }
}

@Suite("reading workspace member patterns")
struct WorkspaceGlobTests {
    @Test("a pnpm workspace file yields its packages list")
    func readsPnpmWorkspace() {
        let globs = DirectoryContext.parsePnpmWorkspace("""
        packages:
          - "apps/*"
          - 'packages/*'
          - tools/cli
        """)
        #expect(globs == ["apps/*", "packages/*", "tools/cli"])
    }

    @Test("comments and blank lines are ignored")
    func ignoresNoise() {
        let globs = DirectoryContext.parsePnpmWorkspace("""
        # everything under apps
        packages:

          - "apps/*"
        """)
        #expect(globs == ["apps/*"])
    }

    @Test("a later top-level key ends the list")
    func stopsAtNextKey() {
        let globs = DirectoryContext.parsePnpmWorkspace("""
        packages:
          - "apps/*"
        catalog:
          - "not-a-package"
        """)
        #expect(globs == ["apps/*"])
    }

    @Test("a file with no packages key yields nothing")
    func emptyWhenAbsent() {
        #expect(DirectoryContext.parsePnpmWorkspace("onlyBuiltDependencies:\n  - esbuild\n").isEmpty)
    }

    @Test("npm and yarn accept both the array and the object form")
    func readsPackageJSONForms() {
        let array = InMemoryFileSystem(["/w/package.json": #"{"workspaces":["apps/*"]}"#])
        let object = InMemoryFileSystem(["/w/package.json": #"{"workspaces":{"packages":["libs/*"]}}"#])
        let url = URL(fileURLWithPath: "/w", isDirectory: true)
        #expect(DirectoryContext.workspaceGlobs(at: url, entries: ["package.json"], fileSystem: array) == ["apps/*"])
        #expect(DirectoryContext.workspaceGlobs(at: url, entries: ["package.json"], fileSystem: object) == ["libs/*"])
    }
}
