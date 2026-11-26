import Foundation
import Testing
@testable import LocalfoxKit

@Suite("finding a real server")
struct ExistingServerFinderTests {
    @Test("only the project listener that serves HTTP is adopted", arguments: [
        ListeningSocket.AddressFamily.ipv4, .ipv6
    ])
    func findsARealServer(family: ListeningSocket.AddressFamily) async throws {
        try await withProjectServer(family: family) { folder, server, port in
            let finder = ExistingServerFinder()
            let found = await finder.find(in: folder, excludingGroups: [], excludingPorts: [])
            #expect(found?.port == port)
            #expect(found?.pid == server.processIdentifier)
            #expect(found?.family == family)

            let own = await finder.find(in: folder, excludingGroups: [getpgid(server.processIdentifier)], excludingPorts: [])
            #expect(own == nil)
            let held = await finder.find(in: folder, excludingGroups: [], excludingPorts: [port])
            #expect(held == nil)
        }
    }

    @Test("an existing server compiling its first HTTP response for three seconds can be adopted")
    func adoptsColdServer() async throws {
        try await withProjectServer(httpDelay: 3) { folder, _, port in
            let found = await ExistingServerFinder().find(in: folder, excludingGroups: [], excludingPorts: [])
            #expect(found?.port == port)
        }
    }

    @Test("a responsive HTTP server is offered while a lower-ranked TCP listener is still silent")
    func adoptsWithoutWaitingForSilentSocket() async throws {
        try await withProjectServer(rawDelay: 12) { folder, _, port in
            let start = ContinuousClock.now
            let found = await ExistingServerFinder().find(in: folder, excludingGroups: [], excludingPorts: [])
            #expect(found?.port == port)
            #expect(ContinuousClock.now - start < .seconds(8))
        }
    }

    @Test("cancelling an in-flight first HTTP request finishes the lookup")
    func cancelsColdServerLookup() async throws {
        try await withProjectServer(httpDelay: 12) { folder, _, _ in
            let lookup = Task { await ExistingServerFinder().find(in: folder, excludingGroups: [], excludingPorts: []) }
            defer { lookup.cancel() }
            let marker = folder.appendingPathComponent("received").path
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker) {
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(FileManager.default.fileExists(atPath: marker))
            let start = ContinuousClock.now
            lookup.cancel()
            #expect(await lookup.value == nil)
            #expect(ContinuousClock.now - start < .seconds(3))
        }
    }

    private func withProjectServer(
        family: ListeningSocket.AddressFamily = .ipv4, httpDelay: Int = 0, rawDelay: Int = 0,
        check: (URL, Process, Int) async throws -> Void
    ) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("localfox-finder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Bind before reporting the ports. Parallel suites and other local processes
        // can take a port between a separate availability check and Python's bind.
        let script = """
        import http.server, pathlib, socket, socketserver, sys, threading, time
        class Web(http.server.ThreadingHTTPServer):
            address_family = socket.AF_INET6 if sys.argv[1] == 'ipv6' else socket.AF_INET
        class Handler(http.server.SimpleHTTPRequestHandler):
            def do_GET(self):
                pathlib.Path('received').touch()
                time.sleep(int(sys.argv[2]))
                super().do_GET()
        class Plain(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.recv(1024)
                time.sleep(int(sys.argv[3]))
                self.request.sendall(b'plain text\\r\\n')
        def listen(server, host, handler, first):
            for port in range(first, first + 1000):
                try:
                    return server((host, port), handler)
                except OSError:
                    continue
            raise RuntimeError('no fixture port available')
        web = listen(Web, '::1' if sys.argv[1] == 'ipv6' else '127.0.0.1', Handler, 31000)
        raw = listen(socketserver.ThreadingTCPServer, '127.0.0.1', Plain, 30000)
        threading.Thread(target=raw.serve_forever, daemon=True).start()
        print(web.server_port, flush=True)
        web.serve_forever()
        """
        let server = Process()
        let output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", script, family.rawValue, String(httpDelay), String(rawDelay)]
        server.currentDirectoryURL = folder
        server.standardOutput = output
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        let port = try #require(Int(line.trimmingCharacters(in: .whitespacesAndNewlines)))

        try await check(folder, server, port)
    }
}
