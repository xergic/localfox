import Foundation
import Security

/// The PKI and issued certificates of one Caddy internal issuer.
public struct CaddyAuthorityStorage {
    private let layout: CaddyLayout
    private let privileged: Bool

    public init(layout: CaddyLayout, privileged: Bool = false) {
        self.layout = layout
        self.privileged = privileged
    }

    public func matchesExpiredRoot(fingerprint: String, now: Date = .now) throws -> Bool {
        try validateDirectories()
        let pem: Data
        do {
            pem = try Data(contentsOf: layout.rootCertificate)
        } catch CocoaError.fileReadNoSuchFile {
            return false
        }
        let root = try Self.parsePEM(pem)
        guard let expiry = SecCertificateCopyNotValidAfterDate(root) else { throw CertificateError.invalidPEM }
        return (expiry as Date) <= now && RootCAEvaluator.fingerprint(of: SecCertificateCopyData(root) as Data) == fingerprint
    }

    /// Call with Caddy stopped. Removing issued leaves first means an interruption
    /// can never leave certificates from the previous root under a new authority.
    public func discardExpiredRoot(fingerprint: String, now: Date = .now) throws {
        guard try matchesExpiredRoot(fingerprint: fingerprint, now: now) else { return }
        let manager = FileManager.default
        let authority = layout.rootCertificate.deletingLastPathComponent()
        let retired = authority.deletingLastPathComponent().appendingPathComponent(".expired-\(layout.caID)")
        let leaves = layout.storageRoot.appendingPathComponent("certificates/\(layout.caID)")
        for directory in [leaves, retired] {
            do { try manager.removeItem(at: directory) } catch CocoaError.fileNoSuchFile { }
        }
        // Clear the old key, root and intermediate together. Recursively deleting
        // the active directory in place could strand half an authority after a crash.
        try manager.moveItem(at: authority, to: retired)
        try manager.removeItem(at: retired)
    }

    /// Validate each parent before traversing it. The leaf-cache and authority
    /// paths are nested below the storage directory Caddy checked at startup.
    private func validateDirectories() throws {
        let storage = layout.storageRoot
        let pki = storage.appendingPathComponent("pki")
        let authorities = pki.appendingPathComponent("authorities")
        let directories = [storage, pki, authorities, authorities.appendingPathComponent(layout.caID),
                           storage.appendingPathComponent("certificates")]
        let parents = privileged ? [storage.deletingLastPathComponent()] + directories : directories
        for directory in parents {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw CaddyError.unsafeDirectory(path: directory.path, reason: "it is not a directory")
                }
                if privileged {
                    let owner = attributes[.ownerAccountID] as? NSNumber
                    let mode = attributes[.posixPermissions] as? NSNumber
                    guard owner?.intValue == 0, let mode, mode.intValue & 0o022 == 0 else {
                        throw CaddyError.unsafeDirectory(path: directory.path, reason: "it must be writable only by root")
                    }
                }
            } catch CocoaError.fileReadNoSuchFile {
                continue
            }
        }
    }

    public static func parsePEM(_ pem: Data) throws -> SecCertificate {
        guard let text = String(data: pem, encoding: .utf8),
              let start = text.range(of: "-----BEGIN CERTIFICATE-----")?.upperBound,
              let end = text.range(of: "-----END CERTIFICATE-----", range: start..<text.endIndex)?.lowerBound,
              let der = Data(base64Encoded: String(text[start..<end]), options: .ignoreUnknownCharacters),
              let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw CertificateError.invalidPEM }
        return certificate
    }

    private enum CertificateError: LocalizedError {
        case invalidPEM

        var errorDescription: String? { "The Localfox authority does not contain a valid X.509 certificate." }
    }
}
