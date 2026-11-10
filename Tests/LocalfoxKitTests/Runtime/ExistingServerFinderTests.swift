import Foundation
import Testing
@testable import LocalfoxKit

@Suite("finding a real server")
struct ExistingServerFinderTests {
    /// Below the ephemeral range, which the matcher ignores, so the OS cannot pick it.
    private static func freePort() throws -> Int {
        try #require((30_000..<31_000).first { CaddySupervisor.isPortFree($0) })
    }

    @Test("a server started in a folder is found there, and not when its group is Localfox's own")
    func findsARealServer() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("localfox-finder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let port = try Self.freePort()

        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
        server.currentDirectoryURL = folder
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }

        for _ in 0..<100 where !PortProbe.accepts(port: port) { try await Task.sleep(for: .milliseconds(50)) }
        let finder = ExistingServerFinder()

        let found = await finder.find(in: folder, excludingGroups: [], excludingPorts: [])
        #expect(found?.port == port)
        #expect(found?.pid == server.processIdentifier)

        let own = await finder.find(in: folder, excludingGroups: [getpgid(server.processIdentifier)], excludingPorts: [])
        #expect(own == nil)
        let held = await finder.find(in: folder, excludingGroups: [], excludingPorts: [port])
        #expect(held == nil)
    }
}
