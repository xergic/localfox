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

    /// The whole path, against a real child: what `kill -9` from a terminal does.
    @Test("a killed child is reaped as signalled")
    func reapsAKilledChild() async throws {
        let request = SpawnRequest.devCommand("sleep 30", in: URL(fileURLWithPath: "/tmp"), shell: "/bin/zsh", environment: [:])
        let process = try ProcessSpawner.spawn(request)
        kill(process.pid, SIGKILL)
        #expect(await ProcessSpawner.reap(process.pid) == .signalled(signal: SIGKILL))
    }
}
