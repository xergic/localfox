import Foundation
import Testing
@testable import LocalfoxKit

@Suite("refusing to run an untrusted binary as root")
struct CaddyBinarySafetyTests {
    /// The bug this guards: `bundledBinary()` ended with a fallback to
    /// `/opt/homebrew/bin/caddy`, and the root daemon's layout reused it. On a
    /// normal Mac `/opt/homebrew/bin` is `admin` group-writable, so any admin
    /// user could place a binary there that the daemon then ran as root.
    @Test("the production layout points only inside the app bundle")
    func productionNeverLeavesTheBundle() {
        let path = CaddyLayout.production().binary.path
        #expect(path.hasSuffix("Contents/MacOS/caddy"))
        #expect(!path.contains("homebrew"))
        #expect(!path.contains("Vendor"))
    }

    @Test("the production layout keeps its state out of the user's home")
    func productionUsesSystemPaths() {
        let layout = CaddyLayout.production()
        #expect(layout.storageRoot.path.hasPrefix("/Library/Application Support/Localfox"))
        #expect(layout.adminSocket.path.hasPrefix("/var/run/localfox"))
        #expect(!layout.storageRoot.path.contains("/Users/"))
    }

    @Test("a symlinked binary is refused rather than resolved")
    func refusesSymlink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localfox-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let link = directory.appendingPathComponent("caddy")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: "/bin/sh")
        )
        #expect(throws: CaddyError.self) {
            try CaddySupervisor.assertSafeToExecuteAsRoot(link, team: "ABCDE12345")
        }
    }

    /// An ad hoc build has no team, and the daemon refuses rather than trusting
    /// whatever it finds. A local `make app` therefore cannot drive the
    /// privileged path, which is the intended trade.
    @Test("a build with no signing team is refused")
    func refusesUnsignedBuild() throws {
        #expect(throws: CaddyError.self) {
            try CaddySupervisor.assertSafeToExecuteAsRoot(
                URL(fileURLWithPath: "/bin/sh"), team: nil
            )
        }
    }

    /// The signature, not the owner, is the invariant. A system binary is signed
    /// by Apple, not by this project's team, so it fails the requirement.
    @Test("a binary signed by a different team is refused")
    func refusesForeignTeam() throws {
        #expect(throws: CaddyError.self) {
            try CaddySupervisor.assertSafeToExecuteAsRoot(
                URL(fileURLWithPath: "/bin/sh"), team: "ZZZZZZZZZZ"
            )
        }
    }
}

@Suite("preparing a directory the daemon writes into")
struct CaddyDirectorySafetyTests {
    private func temporaryParent() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("localfox-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a missing directory is created")
    func createsMissing() throws {
        let parent = try temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }

        let target = parent.appendingPathComponent("runtime", isDirectory: true)
        try CaddySupervisor.prepareDirectory(target, privileged: false)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    /// Following a symlink here would redirect a root write to wherever it points.
    @Test("a symlink standing in for the directory is refused")
    func refusesSymlink() throws {
        let parent = try temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }

        let elsewhere = parent.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let link = parent.appendingPathComponent("runtime")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)

        #expect(throws: CaddyError.self) {
            try CaddySupervisor.prepareDirectory(link, privileged: true)
        }
    }

    @Test("a file where the directory should be is refused")
    func refusesFile() throws {
        let parent = try temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }

        let target = parent.appendingPathComponent("runtime")
        FileManager.default.createFile(atPath: target.path, contents: Data())

        #expect(throws: CaddyError.self) {
            try CaddySupervisor.prepareDirectory(target, privileged: false)
        }
    }

    /// The unprivileged CLI shares this code and must not be blocked by checks
    /// that only make sense for root.
    @Test("an unprivileged caller accepts a directory it already owns")
    func unprivilegedAcceptsOwnDirectory() throws {
        let parent = try temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        try CaddySupervisor.prepareDirectory(parent, privileged: false)
    }

    @Test("a privileged caller refuses a directory it does not own")
    func privilegedRefusesForeignDirectory() throws {
        let parent = try temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        // Owned by the test user, not root.
        #expect(throws: CaddyError.self) {
            try CaddySupervisor.prepareDirectory(parent, privileged: true)
        }
    }
}

@Suite("bounding admin calls")
struct CaddyAdminTimeoutTests {
    /// A socket that accepts and then says nothing, which is what a wedged Caddy
    /// looks like. A refused connection would fail instantly and prove nothing.
    private func silentSocket(at path: String) -> Int32 {
        unlink(path)
        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 100)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(handle, $0, size) }
        }
        listen(handle, 4)
        return handle
    }

    /// Without this the root daemon awaits forever on a wedged socket, its XPC
    /// reply never fires, and the actor stops serving every later request.
    @Test("a socket that accepts but never answers is abandoned, not awaited")
    func timesOutRatherThanHanging() async throws {
        let path = "/tmp/lf-silent-\(UUID().uuidString.prefix(8)).sock"
        let handle = silentSocket(at: path)
        defer { close(handle); unlink(path) }

        let client = CaddyAdminClient(socketPath: path, timeout: 2)
        let started = ContinuousClock.now
        await #expect(throws: (any Swift.Error).self) {
            _ = try await client.config()
        }
        let elapsed = ContinuousClock.now - started

        // It must actually have waited for the bound rather than failing fast,
        // and must not have waited appreciably longer.
        #expect(elapsed > .milliseconds(1500))
        #expect(elapsed < .seconds(8))
    }

    @Test("a socket that does not exist fails immediately rather than waiting")
    func refusedConnectionFailsFast() async throws {
        let client = CaddyAdminClient(
            socketPath: "/tmp/lf-absent-\(UUID().uuidString.prefix(8)).sock", timeout: 5
        )
        let started = ContinuousClock.now
        await #expect(throws: (any Swift.Error).self) {
            _ = try await client.config()
        }
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}
