import Foundation
import Testing
@testable import LocalfoxKit

@Suite("port routes")
struct PortRouteTests {
    private let domain = LocalDomain("db.localhost")!

    @Test("a route pins its port and runs no command")
    func shape() throws {
        let route = try #require(Service.portRoute(name: "DB", domain: domain, port: 8081, directory: nil))
        #expect(route.kind == .portRoute)
        #expect(route.portMode == .fixed(8081))
        #expect(route.command.isEmpty)
        #expect(route.directory == nil)
    }

    @Test("Caddy's own ports and out of range ports are refused", arguments: [0, 80, 443, 65_536])
    func refusesUnroutable(port: Int) {
        #expect(Service.portRoute(name: "X", domain: domain, port: port, directory: nil) == nil)
    }

    @Test("a service written before kinds existed decodes as a command")
    func legacyDecodesAsCommand() throws {
        let json = #"""
        {"id":"7C8E1B0A-3D7E-4C3B-9C55-0E5F4F0B1A22","name":"Web","directory":"file:///Users/me/web/",
         "framework":"unknown","command":"pnpm dev","domain":{"value":"web.localhost"},
         "portMode":{"auto":{}},"portFlagStyle":"none","environment":{}}
        """#
        let service = try JSONDecoder().decode(Service.self, from: Data(json.utf8))
        #expect(service.kind == .command)
        #expect(service.directory == URL(string: "file:///Users/me/web/"))
    }

    @Test("a route without a fixed port is rejected on decode")
    func routeNeedsFixedPort() throws {
        var route = try #require(Service.portRoute(name: "DB", domain: domain, port: 8081, directory: nil))
        route.portMode = .auto
        let data = try JSONEncoder().encode(route)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Service.self, from: data) }
    }

    @Test("waiting is active but not running and has no proxy port")
    func waitingStatus() {
        let status = ServiceStatus.waiting(port: 8081)
        #expect(status.isActive)
        #expect(!status.isRunning)
        #expect(status.port == nil)
        #expect(!status.isTransitioning)
    }

    @Test("a typed port parses only when a route can use it")
    func parsesTypedPort() {
        #expect(Service.routablePort(from: " 8081 ") == 8081)
        #expect(Service.routablePort(from: "443") == nil)
        #expect(Service.routablePort(from: "abc") == nil)
        #expect(Service.routablePort(from: "") == nil)
    }
}
