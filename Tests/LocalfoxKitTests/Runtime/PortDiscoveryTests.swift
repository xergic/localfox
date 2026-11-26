import Darwin
import Foundation
import Synchronization
import Testing
@testable import LocalfoxKit

private func listener(_ port: Int, wildcard: Bool = false) -> DiscoveredListener {
    DiscoveredListener(pid: 1, port: port, family: .ipv4, bindsAllInterfaces: wildcard)
}

@Suite("choosing which listener to proxy")
struct PortScoringTests {
    @Test("the expected port wins outright")
    func expectedPortWins() {
        let chosen = PortDiscovery.best(of: [listener(5173), listener(3000)], expected: 3000)
        #expect(chosen?.port == 3000)
    }

    /// The case the whole product exists for: the preferred port was taken, so
    /// the dev server quietly moved one along.
    @Test("a port just above the expected one beats an unrelated port")
    func nearbyPortBeatsUnrelated() {
        let chosen = PortDiscovery.best(of: [listener(8080), listener(3001)], expected: 3000)
        #expect(chosen?.port == 3001)
    }

    @Test("the node inspector is never chosen", arguments: [9229, 9230, 5858])
    func neverChoosesDebugger(_ debugPort: Int) {
        let chosen = PortDiscovery.best(of: [listener(debugPort), listener(4000)], expected: nil)
        #expect(chosen?.port == 4000)
    }

    @Test("a debugger port is not chosen even when it is the only listener")
    func refusesDebuggerAlone() {
        #expect(PortDiscovery.best(of: [listener(9229)], expected: nil) == nil)
    }

    /// Vite splits its HMR socket onto 24678 when configured to, and proxying
    /// that instead of the app serves nothing.
    @Test("the Vite HMR socket loses to the real server")
    func hmrSocketLoses() {
        let chosen = PortDiscovery.best(of: [listener(24678), listener(5173)], expected: nil)
        #expect(chosen?.port == 5173)
    }

    @Test("an ephemeral port loses to a stable one")
    func ephemeralLoses() {
        let chosen = PortDiscovery.best(of: [listener(51234), listener(4000)], expected: nil)
        #expect(chosen?.port == 4000)
    }

    /// A stable answer matters more than a clever one: the poll runs every
    /// 250 ms and a tie that resolves differently each time would flap the proxy.
    @Test("a tie resolves to the lowest port, and does so consistently")
    func tiesAreStable() {
        let candidates = [listener(8080), listener(4000), listener(6000)]
        let first = PortDiscovery.best(of: candidates, expected: nil)
        let reversed = PortDiscovery.best(of: candidates.reversed(), expected: nil)
        #expect(first?.port == 4000)
        #expect(reversed?.port == 4000)
    }

    @Test("nothing listening means nothing chosen")
    func emptyIsNil() {
        #expect(PortDiscovery.best(of: [], expected: 3000) == nil)
    }
}

@Suite("discovering a real process tree's ports", .tags(.integration))
struct PortDiscoveryIntegrationTests {
    /// Spawns a listener through a shell so the tree is
    /// `sh -> python3`, which is the shape a `pnpm dev` tree has.
    private func spawnListener(port: Int) throws -> SpawnedProcess {
        let script = """
        exec /usr/bin/python3 -c "import socket,time
        s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(('127.0.0.1', \(port))); s.listen(1); time.sleep(30)"
        """
        return try ProcessSpawner.spawn(SpawnRequest(
            executable: "/bin/sh",
            arguments: ["/bin/sh", "-c", script],
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: ["PATH": "/usr/bin:/bin"]
        ))
    }

    @Test("a port opened by a descendant is attributed to the group")
    func findsDescendantPort() async throws {
        let port = Int.random(in: 24000...24800)
        let process = try spawnListener(port: port)
        defer { _ = kill(-process.processGroup, SIGKILL) }

        let discovery = PortDiscovery()
        var found: DiscoveredListener?
        for _ in 0..<40 {
            found = discovery.listeners(inGroup: process.processGroup).first { $0.port == port }
            if found != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(found?.port == port)
        #expect(found?.bindsAllInterfaces == false)
    }

    @Test("discovery skips plain TCP and confirms the lower-ranked IPv6 HTTP listener", .timeLimit(.minutes(1)))
    func confirmsOnlyHTTP() async throws {
        let script = """
        import http.server, socket, socketserver, threading
        class Raw(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.recv(1024)
                self.request.sendall(b'plain text\\r\\n')
        class HTTP(http.server.ThreadingHTTPServer):
            address_family = socket.AF_INET6
        raw = socketserver.ThreadingTCPServer(('127.0.0.1', 0), Raw)
        web = HTTP(('::1', 0), http.server.SimpleHTTPRequestHandler)
        threading.Thread(target=raw.serve_forever, daemon=True).start()
        print(raw.server_address[1], web.server_port, flush=True)
        web.serve_forever()
        """
        let process = try ProcessSpawner.spawn(SpawnRequest(
            executable: "/usr/bin/python3", arguments: ["/usr/bin/python3", "-c", script],
            workingDirectory: FileManager.default.temporaryDirectory, environment: [:]
        ))
        defer {
            _ = kill(-process.processGroup, SIGKILL)
            _ = waitpid(process.pid, nil, 0)
        }
        let line = String(decoding: process.standardOutput.availableData, as: UTF8.self)
        let ports = line.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        try #require(ports.count == 2)
        let slowStarts = Mutex(0)
        let listener = try await PortDiscovery().waitForHTTP(
            group: process.processGroup, expected: ports[0], host: "web.localhost", slowAfter: .milliseconds(10)
        ) { slowStarts.withLock { $0 += 1 } }
        #expect(slowStarts.withLock { $0 } == 1)
        #expect(listener.port == ports[1])
        #expect(listener.family == .ipv6)
    }

    @Test("cancelling an unbounded startup promptly leaves discovery")
    func cancelStartup() async throws {
        let process = try ProcessSpawner.spawn(SpawnRequest(
            executable: "/bin/sleep", arguments: ["/bin/sleep", "10"],
            workingDirectory: FileManager.default.temporaryDirectory, environment: [:]
        ))
        defer {
            _ = kill(-process.processGroup, SIGKILL)
            _ = waitpid(process.pid, nil, 0)
        }
        let wait = Task {
            try await PortDiscovery().waitForPort(group: process.processGroup, expected: nil, timeout: nil)
        }
        try await Task.sleep(for: .milliseconds(50))
        wait.cancel()
        await #expect(throws: CancellationError.self) { try await wait.value }
    }

    /// `POSIX_SPAWN_SETSID` is what makes this true, and it is the whole reason
    /// `Foundation.Process` is not used: without a session, a signal cannot
    /// reach a grandchild that reparented to launchd.
    @Test("the spawned process leads its own group")
    func spawnLeadsItsGroup() throws {
        let process = try spawnListener(port: Int.random(in: 24800...25000))
        defer { _ = kill(-process.processGroup, SIGKILL) }
        #expect(process.processGroup == process.pid)
        #expect(getpgid(process.pid) == process.pid)
    }

    @Test("terminating the group leaves nothing behind")
    func terminateReapsTheTree() async throws {
        let process = try spawnListener(port: Int.random(in: 25000...25400))
        // Let the shell exec and the child bind before signalling.
        try await Task.sleep(for: .milliseconds(400))

        let outcome = await ProcessSpawner.terminate(group: process.processGroup)
        #expect(outcome == .exited || outcome == .killed)
        #expect(ProcessSpawner.isAlive(process.processGroup) == false)
    }

    @Test("terminating a group that is already gone is not an error")
    func terminateIsIdempotent() async throws {
        let process = try spawnListener(port: Int.random(in: 25400...25800))
        _ = await ProcessSpawner.terminate(group: process.processGroup)
        #expect(await ProcessSpawner.terminate(group: process.processGroup) == .alreadyGone)
    }

    /// The guard that stops a bad group id taking down the user's shell, or
    /// Localfox itself.
    @Test("Localfox refuses to signal its own process group")
    func refusesOwnGroup() async {
        let outcome = await ProcessSpawner.terminate(group: getpgrp())
        #expect(outcome == .refused(reason: "Localfox's own process group"))
    }
}
