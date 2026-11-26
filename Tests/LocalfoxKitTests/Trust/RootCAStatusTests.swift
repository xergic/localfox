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
        #expect(status.removalFingerprint == nil)
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
        #expect(status.removalFingerprint == root.fingerprint)
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
        #expect(status.removalFingerprint == "old")
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
        #expect(status == .expired(root, installed: root))
        #expect(status.remedy == .regenerate)
        #expect(status.removalFingerprint == root.fingerprint)
        let absent = RootCAEvaluator.evaluate(current: root, installed: [], trustEvaluationPassed: false, now: now)
        #expect(absent.removalFingerprint == nil)
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
            .stale(installed: root, current: root), .expired(root, installed: root),
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

@Suite("replacing trust in the login keychain")
struct RootCAReplacementTests {
    private enum Failure: Error { case cancelled, cleanupDenied }

    private actor Keychain {
        var trusted: Set<String> = ["old"]
        var operations: [String] = []

        func trustNew(cancel: Bool = false) throws {
            operations.append("trust new")
            if cancel { throw Failure.cancelled }
            trusted.insert("new")
        }

        func remove(_ fingerprint: String, deny: Bool = false) throws {
            operations.append("remove \(fingerprint)")
            if deny { throw Failure.cleanupDenied }
            trusted.remove(fingerprint)
        }
    }

    private let old = authority("old")
    private let new = authority("new")
    private var previous: RootCAStatus { .stale(installed: old, current: new) }

    @Test("cancelling trust keeps the old root and never requests its removal")
    func cancelInstall() async throws {
        let keychain = Keychain()
        await #expect(throws: Failure.cancelled) {
            _ = try await previous.install(
                fingerprint: new.fingerprint,
                trustCurrent: { try await keychain.trustNew(cancel: true) },
                removeSuperseded: { try await keychain.remove($0) }
            )
        }
        #expect(await keychain.trusted == ["old"])
        #expect(await keychain.operations == ["trust new"])
        // SecItemAdd can already have succeeded when the trust prompt is cancelled.
        #expect(RootCAEvaluator.evaluate(current: new, installed: [new, old], trustEvaluationPassed: false, now: now) == previous)
    }

    @Test("trust succeeds even when the old keychain entry cannot be removed")
    func cleanupFailure() async throws {
        let keychain = Keychain()
        let warning = try await previous.install(
            fingerprint: new.fingerprint,
            trustCurrent: { try await keychain.trustNew() },
            removeSuperseded: { try await keychain.remove($0, deny: true) }
        )
        #expect(warning?.contains("SHA-256 old") == true)
        #expect(await keychain.trusted == ["new", "old"])
        #expect(await keychain.operations == ["trust new", "remove old"])
        #expect(RootCAEvaluator.evaluate(current: new, installed: [old, new], trustEvaluationPassed: true, now: now).isUsable)
    }

    @Test("successful replacement trusts the new root before removing the superseded fingerprint")
    func success() async throws {
        let keychain = Keychain()
        let warning = try await previous.install(
            fingerprint: new.fingerprint,
            trustCurrent: { try await keychain.trustNew() },
            removeSuperseded: { try await keychain.remove($0) }
        )
        #expect(warning == nil)
        #expect(await keychain.trusted == ["new"])
        #expect(await keychain.operations == ["trust new", "remove old"])
    }
}
