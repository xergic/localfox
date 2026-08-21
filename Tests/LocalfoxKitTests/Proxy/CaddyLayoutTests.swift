import Foundation
import Testing

@testable import LocalfoxKit

@Suite("caddy layout CA identity")
struct CaddyLayoutTests {
    /// Two authorities generated into different storage roots under one id and
    /// one subject name are indistinguishable in a keychain, so a user who trusts
    /// the CLI's root makes the app report a root it is not serving from.
    @Test("the development and production layouts use distinct authorities")
    func layoutsDoNotShareAnAuthority() {
        let development = CaddyLayout.development()
        let production = CaddyLayout.production()
        #expect(development.caID != production.caID)
        #expect(development.caName != production.caName)
        #expect(development.storageRoot != production.storageRoot)
    }

    @Test("the root certificate path follows the authority id")
    func rootCertificateFollowsCAID() {
        let production = CaddyLayout.production()
        #expect(
            production.rootCertificate.path
                == "/Library/Application Support/Localfox/caddy/pki/authorities/localfox/root.crt"
        )
        #expect(CaddyLayout.development().rootCertificate.path.hasSuffix("authorities/localfox-dev/root.crt"))
    }
}
