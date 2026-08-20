import Testing
@testable import LocalfoxKit

@Suite("validating privileged helper requests")
struct HelperRequestValidatorTests {
    @Test("a SHA-256 fingerprint is exactly 64 hexadecimal characters")
    func acceptsFingerprint() {
        let fingerprint = String(repeating: "aB01", count: 16)
        #expect(HelperRequestValidator.isValidFingerprint(fingerprint))
    }

    @Test("malformed fingerprints are rejected", arguments: [
        String(repeating: "a", count: 63),
        String(repeating: "a", count: 65),
        String(repeating: "g", count: 64),
        "",
        String(repeating: "a", count: 63) + ";",
        String(repeating: "a", count: 63) + " ",
        String(repeating: "a", count: 63) + "/",
        String(repeating: "a", count: 63) + "`"
    ])
    func rejectsFingerprint(_ fingerprint: String) {
        #expect(HelperRequestValidator.isValidFingerprint(fingerprint) == false)
    }

    @Test("route identifiers use the ProxyRoute grammar")
    func validatesRouteID() {
        #expect(HelperRequestValidator.isValidRouteID("web_1-production"))
        #expect(HelperRequestValidator.isValidRouteID(String(repeating: "a", count: 32)))
        #expect(HelperRequestValidator.isValidRouteID("") == false)
        #expect(HelperRequestValidator.isValidRouteID(String(repeating: "a", count: 33)) == false)
        #expect(HelperRequestValidator.isValidRouteID("../web") == false)
        #expect(HelperRequestValidator.isValidRouteID("web/../../etc") == false)
    }

    @Test("log requests are clamped to a bounded nonnegative range")
    func clampsLogLines() {
        #expect(HelperRequestValidator.clampLogLines(-1) == 0)
        #expect(HelperRequestValidator.clampLogLines(0) == 0)
        #expect(HelperRequestValidator.clampLogLines(25) == 25)
        #expect(HelperRequestValidator.clampLogLines(10_000) == 1_000)
    }
}
