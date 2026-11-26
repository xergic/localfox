import Foundation
import LocalfoxKit

@MainActor
extension AppState {
    func installCertificate() async {
        guard !isChangingCertificate else { return }
        isChangingCertificate = true
        defer { isChangingCertificate = false }
        clearError()
        let message: String?
        do {
            let previous = trust
            if case let .expired(root, _) = previous {
                try await helperClient.regenerateRootCA(fingerprint: root.fingerprint)
                await refreshSetup()
            }
            guard let pem = try await helperClient.exportRootCA() else {
                throw UserTrustStoreError.noRoot
            }
            let current = try TrustEvaluator.identity(for: TrustEvaluator.parsePEM(pem))
            guard current.notAfter > .now else { throw UserTrustStoreError.expiredRoot }
            message = try await previous.install(
                fingerprint: current.fingerprint,
                trustCurrent: { try await UserTrustStore.install(pem: pem) },
                removeSuperseded: { try await UserTrustStore.remove(fingerprint: $0) }
            )
            Telemetry.send(.certificateTrusted(.success))
        } catch {
            message = error.localizedDescription
            Telemetry.send(.certificateTrusted(.failure))
        }
        await refreshTrust()
        if let message { report(message) }
    }

    func removeCertificate() async {
        guard !isChangingCertificate, let fingerprint = trust.removalFingerprint else { return }
        isChangingCertificate = true
        defer { isChangingCertificate = false }
        clearError()
        do {
            try await UserTrustStore.remove(fingerprint: fingerprint)
            Telemetry.send(.certificateUntrusted(.success))
        } catch {
            report(error.localizedDescription)
            Telemetry.send(.certificateUntrusted(.failure))
        }
        await refreshTrust()
    }
}
