import Foundation
import Testing
@testable import LocalfoxKit

@Suite("validating a proxy route")
struct ProxyRouteTests {
    private let domain = LocalDomain("wishfox.localhost")!

    @Test("valid route values are accepted")
    func acceptsValidValues() {
        #expect(ProxyRoute(id: "wishfox_1", domain: domain, port: 3000) != nil)
    }

    @Test("invalid ports and ids are rejected")
    func rejectsInvalidValues() {
        #expect(ProxyRoute(id: "web", domain: domain, port: 0) == nil)
        #expect(ProxyRoute(id: "web", domain: domain, port: 65_536) == nil)
        #expect(ProxyRoute(id: "web", domain: domain, port: -1) == nil)
        #expect(ProxyRoute(id: "../x", domain: domain, port: 3000) == nil)
        #expect(LocalDomain("wishfox.example") == nil)
    }

    @Test("an absent family decodes as IPv4 and an IPv6 route survives the XPC payload")
    func roundTripsLoopbackFamily() throws {
        let legacy = Data(#"{"id":"web","domain":{"value":"wishfox.localhost"},"port":3000}"#.utf8)
        #expect(try JSONDecoder().decode(ProxyRoute.self, from: legacy).family == .ipv4)
        let route = try #require(ProxyRoute(id: "web", domain: domain, port: 3000, family: .ipv6))
        #expect(try JSONDecoder().decode(ProxyRoute.self, from: JSONEncoder().encode(route)) == route)
    }

    @Test("malformed JSON cannot cross the XPC boundary")
    func rejectsMalformedJSON() {
        let decoder = JSONDecoder()
        let invalidPort = Data("{\"id\":\"web\",\"domain\":{\"value\":\"wishfox.localhost\"},\"port\":99999}".utf8)
        let invalidDomain = Data("{\"id\":\"web\",\"domain\":{\"value\":\"wishfox.example\"},\"port\":3000}".utf8)
        #expect(throws: (any Error).self) { try decoder.decode(ProxyRoute.self, from: invalidPort) }
        #expect(throws: (any Error).self) { try decoder.decode(ProxyRoute.self, from: invalidDomain) }
    }
}
