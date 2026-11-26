import Foundation
import Testing

@testable import LocalfoxKit

@Suite("reading how a dev server ended")
struct ExitStatusTests {
    @Test("a normal exit carries its code")
    func exitCode() {
        #expect(ProcessSpawner.failureReason(waitStatus: 1 << 8) == .exited(code: 1))
    }

    @Test("a kill carries its signal")
    func signal() {
        #expect(ProcessSpawner.failureReason(waitStatus: SIGKILL) == .signalled(signal: SIGKILL))
    }

    @Test("editable shell commands pass environment assignments and run every compound step")
    func executesUserShellSyntax() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = folder.appendingPathComponent("result")
        let request = SpawnRequest.devCommand(
            "LOCALFOX_TEST=yes /usr/bin/printenv LOCALFOX_TEST > result && /bin/echo done >> result",
            in: folder, shell: "/bin/zsh", environment: ["ZDOTDIR": folder.path]
        )
        let process = try ProcessSpawner.spawn(request)
        #expect(await ProcessSpawner.reap(process.pid) == .exited(code: 0))
        #expect(try String(contentsOf: result, encoding: .utf8) == "yes\ndone\n")
    }

    @Test("a server that closes its logs early still reports its eventual exit")
    func reapsAfterOutputCloses() async throws {
        let request = SpawnRequest(
            executable: "/usr/bin/python3",
            arguments: ["python3", "-c", "import os,time; os.closerange(1,256); time.sleep(2.2); os._exit(24)"],
            workingDirectory: FileManager.default.temporaryDirectory, environment: [:]
        )
        let process = try ProcessSpawner.spawn(request)
        #expect(process.standardOutput.availableData.isEmpty)
        #expect(await ProcessSpawner.reap(process.pid, within: nil) == .exited(code: 24))
    }

    /// The whole path, against a real child: what `kill -9` from a terminal does.
    @Test("a killed child is reaped as signalled")
    func reapsAKilledChild() async throws {
        let request = SpawnRequest.devCommand("sleep 30", in: URL(fileURLWithPath: "/tmp"), shell: "/bin/zsh", environment: [:])
        let process = try ProcessSpawner.spawn(request)
        kill(process.pid, SIGKILL)
        #expect(await ProcessSpawner.reap(process.pid) == .signalled(signal: SIGKILL))
    }
}
