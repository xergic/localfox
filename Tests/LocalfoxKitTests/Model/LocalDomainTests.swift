import Foundation
import Testing
@testable import LocalfoxKit

@Suite("validating a local domain")
struct LocalDomainTests {
    @Test("a plain project domain is accepted")
    func acceptsApex() {
        #expect(LocalDomain("wishfox.localhost")?.value == "wishfox.localhost")
    }

    @Test("a service subdomain is accepted")
    func acceptsSubdomain() {
        #expect(LocalDomain("api.wishfox.localhost")?.value == "api.wishfox.localhost")
    }

    @Test("the host is lowercased")
    func lowercases() {
        #expect(LocalDomain("API.Wishfox.LocalHost")?.value == "api.wishfox.localhost")
    }

    @Test("any suffix other than .localhost is rejected", arguments: [
        "wishfox.test", "wishfox.local", "wishfox.com", "localhost", "wishfox"
    ])
    func rejectsOtherSuffixes(_ host: String) {
        #expect(LocalDomain(host) == nil)
    }

    /// These are the shapes that would let a caller smuggle something past the
    /// helper and into a Caddy host matcher.
    @Test("hostile labels are rejected", arguments: [
        "", ".localhost", "..localhost", "a..b.localhost", "-lead.localhost",
        "trail-.localhost", "has space.localhost", "has/slash.localhost",
        "../x.localhost", "evil.com#.localhost", "x@y.localhost"
    ])
    func rejectsHostileLabels(_ host: String) {
        #expect(LocalDomain(host) == nil)
    }

    @Test("a label longer than 63 characters is rejected")
    func rejectsOverlongLabel() {
        #expect(LocalDomain(String(repeating: "a", count: 64) + ".localhost") == nil)
        #expect(LocalDomain(String(repeating: "a", count: 63) + ".localhost") != nil)
    }

    @Test("slug turns a project name into a usable label", arguments: [
        ("Wishfox", "wishfox"), ("my app", "my-app"), ("@acme/web", "acme-web"),
        ("  Trailing  ", "trailing"), ("a__b", "a-b")
    ])
    func slugs(_ input: String, _ expected: String) {
        #expect(LocalDomain.slug(input) == expected)
    }
}
