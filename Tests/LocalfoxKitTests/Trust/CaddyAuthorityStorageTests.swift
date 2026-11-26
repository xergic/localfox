import Foundation
import Security
import Testing
@testable import LocalfoxKit

@Suite("renewing the Localfox certificate authority")
struct CaddyAuthorityStorageTests {
    private let pem = Data("""
        -----BEGIN CERTIFICATE-----
        MIICHTCCAcQCCQDGsMU9UmxzSTAKBggqhkjOPQQDAjAdMRswGQYDVQQDDBJMb2Nh
        bGZveCB0ZXN0IHJvb3QwHhcNMjYxMTI2MTQxNzQ0WhcNMjYxMTI3MTQxNzQ0WjAd
        MRswGQYDVQQDDBJMb2NhbGZveCB0ZXN0IHJvb3QwggFLMIIBAwYHKoZIzj0CATCB
        9wIBATAsBgcqhkjOPQEBAiEA/////wAAAAEAAAAAAAAAAAAAAAD/////////////
        //8wWwQg/////wAAAAEAAAAAAAAAAAAAAAD///////////////wEIFrGNdiqOpPn
        s+u9VXaYhrxlHQawzFOw9jvOPD4n0mBLAxUAxJ02CIbnBJNqZnjhE50mt4GffpAE
        QQRrF9Hy4SxCR/i85uVjpEDydwN9gS3rM6D0oTlF2JjClk/jQuL+Gn+bjufrSnwP
        nhYrzjNXazFezsu2QGg3v1H1AiEA/////wAAAAD//////////7zm+q2nF56E87nK
        wvxjJVECAQEDQgAEzXwT6k+AMfx2k0nFjwPemtWQtIW7YQfKUQ3tzMyQOXkbg6pm
        ke0zAqoeaK045SzWxTmWHGW/s2jGURoUx4/lNzAKBggqhkjOPQQDAgNHADBEAiBj
        N8AcJtUiFCCvgicINg0Pt5TwwuBnmgD+7I3b9xL05wIgZ8gCOZhd3jgmzcz7x0yh
        g5PHgmwrD0ClD3fY01vGDBY=
        -----END CERTIFICATE-----
        """.utf8)

    @Test("renewal retires only the expired issuer and its issued leaves, and tolerates a repeated request")
    func renewExpiredAuthority() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let layout = CaddyLayout(
            binary: base, storageRoot: base, adminSocket: base, logFile: base,
            configFile: base, caID: "localfox", caName: "Localfox Test"
        )
        let authority = CaddyAuthorityStorage(layout: layout)
        let leaf = base.appendingPathComponent("certificates/localfox/site.localhost/site.crt")
        let other = base.appendingPathComponent("certificates/another/other.crt")
        let intermediate = layout.rootCertificate.deletingLastPathComponent().appendingPathComponent("intermediate.key")
        for file in [layout.rootCertificate, intermediate, leaf, other] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try pem.write(to: file)
        }
        let certificate = try CaddyAuthorityStorage.parsePEM(pem)
        let digest = RootCAEvaluator.fingerprint(of: SecCertificateCopyData(certificate) as Data)

        try authority.discardExpiredRoot(fingerprint: digest, now: .distantPast)
        try authority.discardExpiredRoot(fingerprint: "old-selection", now: .distantFuture)
        #expect(try Data(contentsOf: layout.rootCertificate) == pem)
        #expect(try Data(contentsOf: leaf) == pem)

        try authority.discardExpiredRoot(fingerprint: digest, now: .distantFuture)
        #expect(!FileManager.default.fileExists(atPath: layout.rootCertificate.path))
        #expect(!FileManager.default.fileExists(atPath: intermediate.path))
        #expect(!FileManager.default.fileExists(atPath: leaf.path))
        #expect(try Data(contentsOf: other) == pem)
        try authority.discardExpiredRoot(fingerprint: digest, now: .distantFuture)
    }
}
