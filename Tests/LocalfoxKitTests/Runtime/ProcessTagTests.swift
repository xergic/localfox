import Foundation
import Testing
@testable import LocalfoxKit

@Suite("Finding a server that left its process group")
struct ProcessTagTests {
    /// A copy, because the kernel withholds a platform binary's environment, and
    /// `/bin/sleep` is one. A dev server's `node` or `bun` is not.
    private func taggedSleep(id: String, in directory: URL) throws -> Process {
        let sleep = directory.appendingPathComponent("sleep")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: sleep)
        let child = Process()
        child.executableURL = sleep
        child.arguments = ["30"]
        child.environment = ["LOCALFOX_ID": id]
        try child.run()
        return child
    }

    @Test("a process carrying the tag is found, and stopped")
    func taggedProcessIsFoundAndStopped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("localfox-tag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID().uuidString
        let child = try taggedSleep(id: id, in: directory)
        defer { if child.isRunning { child.terminate() } }

        // `run` returns before the child has exec'd, and until then its
        // environment is still this process's. Polled, because under a parallel
        // test run the exec can take far longer than it does alone.
        var found: [ProcessSnapshot] = []
        for _ in 0..<50 where found.isEmpty {
            found = ProcessInspector().processes(taggedWith: id)
            if found.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(found.map(\.pid) == [child.processIdentifier])
        #expect(ProcessInspector().processes(taggedWith: UUID().uuidString).isEmpty)

        await ProcessSpawner.terminate(tagged: id, found)
        child.waitUntilExit()
        #expect(!child.isRunning)
    }

    @Test("environment entries start after argv")
    func environmentFollowsArguments() {
        var buffer = withUnsafeBytes(of: Int32(2)) { Array($0) }
        buffer += Array("/usr/bin/node".utf8) + [0, 0, 0]
        for entry in ["node", "LOCALFOX_ID=not-env", "LOCALFOX_ID=abc", "PATH=/usr/bin"] {
            buffer += Array(entry.utf8) + [0]
        }

        let entries = ProcessInspector.environment(in: buffer).map { String(decoding: $0, as: UTF8.self) }

        #expect(entries == ["LOCALFOX_ID=abc", "PATH=/usr/bin"])
    }

    @Test("a pid whose process changed is never signalled")
    func recycledPidIsLeftAlone() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        let stale = ProcessSnapshot(
            pid: child.processIdentifier, parentPID: getpid(), uid: getuid(),
            startTime: Date(timeIntervalSince1970: 1)
        )

        await ProcessSpawner.terminate(tagged: UUID().uuidString, [stale], grace: .milliseconds(200))

        #expect(child.isRunning)
    }
}
