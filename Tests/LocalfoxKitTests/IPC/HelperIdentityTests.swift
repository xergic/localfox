import Foundation
import Testing

@testable import LocalfoxKit

@Suite("helper registration preconditions")
struct HelperIdentityTests {
    @Test("an app outside /Applications is reported before a doomed register()")
    func rejectsBundleOutsideApplications() {
        let blocker = HelperIdentity.registrationBlocker(
            bundleURL: URL(fileURLWithPath: "/Users/someone/Work/localfox/dist/Localfox.app"),
            teamIdentifier: "ABCDE12345"
        )
        #expect(blocker == .notInApplications("/Users/someone/Work/localfox/dist"))
    }

    @Test("an ad hoc signed build is reported, because its helper would refuse every peer")
    func rejectsMissingTeamIdentifier() {
        let blocker = HelperIdentity.registrationBlocker(
            bundleURL: URL(fileURLWithPath: "/Applications/Localfox.app"),
            teamIdentifier: nil
        )
        #expect(blocker == .noTeamIdentifier)
    }

    @Test("a signed app in /Applications has nothing blocking it")
    func acceptsSignedBundleInApplications() {
        let blocker = HelperIdentity.registrationBlocker(
            bundleURL: URL(fileURLWithPath: "/Applications/Localfox.app"),
            teamIdentifier: "ABCDE12345"
        )
        #expect(blocker == nil)
    }

    @Test("a path merely containing Applications is not /Applications")
    func rejectsLookalikePath() {
        let blocker = HelperIdentity.registrationBlocker(
            bundleURL: URL(fileURLWithPath: "/Users/someone/Applications/Localfox.app"),
            teamIdentifier: "ABCDE12345"
        )
        #expect(blocker == .notInApplications("/Users/someone/Applications"))
    }
}
