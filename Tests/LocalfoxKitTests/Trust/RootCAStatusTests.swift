import Foundation
import Testing
@testable import LocalfoxKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func authority(
    _ fingerprint: String,
    name: String = "Localfox Local Authority",
    expiresInDays: Double = 365
) -> RootCAIdentity {
    RootCAIdentity(
        fingerprint: fingerprint,
        commonName: name,
        notBefore: now.addingTimeInterval(-86_400),
        notAfter: now.addingTimeInterval(expiresInDays * 86_400)
    )
}

@Suite("judging local HTTPS trust")
struct RootCAStatusTests {
    @Test("before Caddy has run there is nothing to trust")
    func nothingGenerated() {
        let status = RootCAEvaluator.evaluate(
            current: nil, installed: [], trustEvaluationPassed: false, now: now
        )
        #expect(status == .notGenerated)
        #expect(status.remedy == .startProxy)
        #expect(status.isUsable == false)
    }

    @Test("a root that exists but is in no keychain needs installing")
    func notInstalled() {
        let root = authority("aa")
        let status = RootCAEvaluator.evaluate(
            current: root, installed: [], trustEvaluationPassed: false, now: now
        )
        #expect(status == .notInstalled(root))
        #expect(status.remedy == .install)
    }

    /// The state fingerprint matching alone cannot see. A certificate can sit in
    /// the keychain with its trust setting denied, and reporting that as trusted
    /// puts a green badge next to a browser warning.
    @Test("installed but failing trust evaluation is not trusted")
    func installedButDenied() {
        let root = authority("bb")
        let status = RootCAEvaluator.evaluate(
            current: root, installed: [root], trustEvaluationPassed: false, now: now
        )
        #expect(status == .installedNotTrusted(root))
        #expect(status.remedy == .reinstall)
        #expect(status.isUsable == false)
    }

    @Test("installed and passing trust evaluation is trusted")
    func trusted() {
        let root = authority("cc")
        let status = RootCAEvaluator.evaluate(
            current: root, installed: [root], trustEvaluationPassed: true, now: now
        )
        #expect(status.isUsable)
        #expect(status.remedy == .none)
        #expect(status.identity == root)
    }

    /// Regenerating the CA leaves the old root behind. Repair has to remove that
    /// specific one, so the status must carry it rather than only the new one.
    @Test("a leftover root from a regenerated CA reports as stale and names both")
    func staleNamesTheOldRoot() {
        let old = authority("old")
        let new = authority("new")
        let status = RootCAEvaluator.evaluate(
            current: new, installed: [old], trustEvaluationPassed: true, now: now
        )
        #expect(status == .stale(installed: old, current: new))
        #expect(status.remedy == .repair)
        #expect(status.isUsable == false)

        guard case let .stale(installed, current) = status else {
            Issue.record("expected stale")
            return
        }
        // Removal is by fingerprint, so these must not be the same value.
        #expect(installed.fingerprint == "old")
        #expect(current.fingerprint == "new")
    }

    @Test("fingerprint comparison ignores case")
    func fingerprintsAreCaseInsensitive() {
        let root = authority("ABCDEF")
        let sameRoot = authority("abcdef")
        let status = RootCAEvaluator.evaluate(
            current: root, installed: [sameRoot], trustEvaluationPassed: true, now: now
        )
        #expect(status.isUsable)
    }

    /// Expiry outranks trust because an evaluation against an expired root fails
    /// anyway, and "expired" is the message that explains why.
    @Test("an expired root reports as expired even when it is installed and trusted")
    func expiredOutranksTrust() {
        let root = authority("dd", expiresInDays: -1)
        let status = RootCAEvaluator.evaluate(
            current: root, installed: [root], trustEvaluationPassed: true, now: now
        )
        #expect(status == .expired(root))
        #expect(status.remedy == .regenerate)
    }

    @Test("a root inside the warning window is flagged as expiring soon")
    func warnsBeforeExpiry() {
        let soon = authority("ee", expiresInDays: 10)
        let later = authority("ff", expiresInDays: 200)
        let soonStatus = RootCAEvaluator.evaluate(
            current: soon, installed: [soon], trustEvaluationPassed: true, now: now
        )
        let laterStatus = RootCAEvaluator.evaluate(
            current: later, installed: [later], trustEvaluationPassed: true, now: now
        )
        #expect(RootCAEvaluator.isExpiringSoon(soonStatus, now: now))
        #expect(RootCAEvaluator.isExpiringSoon(laterStatus, now: now) == false)
    }

    @Test("an untrusted state is never reported as expiring soon")
    func onlyTrustedExpires() {
        let root = authority("gg", expiresInDays: 1)
        let status = RootCAEvaluator.evaluate(
            current: root, installed: [], trustEvaluationPassed: false, now: now
        )
        #expect(RootCAEvaluator.isExpiringSoon(status, now: now) == false)
    }

    @Test("every state offers exactly one remedy")
    func everyStateHasARemedy() {
        let root = authority("hh")
        let states: [RootCAStatus] = [
            .notGenerated, .notInstalled(root), .installedNotTrusted(root),
            .stale(installed: root, current: root), .expired(root),
            .trusted(root, expiresIn: 100)
        ]
        for state in states where state.isUsable == false {
            #expect(state.remedy != .none, "\(state) needs an action the user can take")
        }
    }

    @Test("the fingerprint is lowercase hex SHA-256 of the DER")
    func fingerprintsAreSHA256() {
        // Known vector: SHA-256 of the empty input.
        let digest = RootCAEvaluator.fingerprint(of: Data())
        #expect(digest == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(digest.count == 64)
    }
}
