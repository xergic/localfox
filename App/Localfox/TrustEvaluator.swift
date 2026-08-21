import Foundation
import LocalfoxKit
import Security

enum TrustEvaluator {
    struct ParsedCertificate {
        let der: Data
        let certificate: SecCertificate
    }

    static func parsePEM(_ pem: Data) throws -> ParsedCertificate {
        guard let text = String(data: pem, encoding: .utf8),
              let bodyStart = text.range(of: "-----BEGIN CERTIFICATE-----")?.upperBound,
              let bodyEnd = text.range(of: "-----END CERTIFICATE-----", range: bodyStart..<text.endIndex)?.lowerBound,
              let der = Data(base64Encoded: String(text[bodyStart..<bodyEnd]), options: .ignoreUnknownCharacters),
              !der.isEmpty,
              let certificate = SecCertificateCreateWithData(nil, der as CFData)
        else {
            throw TrustEvaluatorError.invalidPEM
        }
        return ParsedCertificate(der: der, certificate: certificate)
    }

    static func identity(for parsedCertificate: ParsedCertificate) throws -> RootCAIdentity {
        var copiedCommonName: CFString?
        guard SecCertificateCopyCommonName(parsedCertificate.certificate, &copiedCommonName) == errSecSuccess,
              let commonName = copiedCommonName as String?
        else {
            throw TrustEvaluatorError.missingCommonName
        }

        let dates = try validityDates(of: parsedCertificate.certificate)
        return RootCAIdentity(
            fingerprint: RootCAEvaluator.fingerprint(of: parsedCertificate.der),
            commonName: commonName,
            notBefore: dates.notBefore,
            notAfter: dates.notAfter
        )
    }

    static func installedRoots() throws -> [RootCAIdentity] {
        // The authority's own name, not "Localfox". Caddy derives the subject
        // from it as "<name> - <year> ECC Root", and a bare "Localfox" also
        // matches the CLI's development authority, which would make a
        // hand-trusted dev root report the production one as stale.
        let query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecMatchSubjectContains: CaddyLayout.production().caName as CFString,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnRef: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw TrustEvaluatorError.keychain(status)
        }
        guard let certificates = result as? [SecCertificate] else {
            throw TrustEvaluatorError.invalidKeychainResult
        }

        return try certificates.map { certificate in
            let parsedCertificate = ParsedCertificate(
                der: SecCertificateCopyData(certificate) as Data,
                certificate: certificate
            )
            return try identity(for: parsedCertificate)
        }
    }

    static func trustEvaluationPassed(
        leaf: SecCertificate?,
        root: SecCertificate,
        host: String
    ) throws -> Bool {
        let certificates: CFTypeRef
        let policy: SecPolicy
        if let leaf {
            certificates = [leaf, root] as CFArray
            policy = SecPolicyCreateSSL(true, host as CFString)
        } else {
            // Until Caddy has issued a leaf, evaluating the root with a basic
            // policy is the only system-trust signal available.
            certificates = root
            policy = SecPolicyCreateBasicX509()
        }

        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificates, policy, &trust)
        guard status == errSecSuccess, let trust else {
            throw TrustEvaluatorError.createTrust(status)
        }
        return SecTrustEvaluateWithError(trust, nil)
    }

    static func evaluate(
        rootPEM: Data?,
        issuedLeaf: SecCertificate? = nil,
        host: String
    ) throws -> RootCAStatus {
        let installed = try installedRoots()
        guard let rootPEM else {
            return RootCAEvaluator.evaluate(
                current: nil,
                installed: installed,
                trustEvaluationPassed: false
            )
        }

        let parsedRoot = try parsePEM(rootPEM)
        let current = try identity(for: parsedRoot)
        let isTrusted = try trustEvaluationPassed(
            leaf: issuedLeaf,
            root: parsedRoot.certificate,
            host: host
        )
        return RootCAEvaluator.evaluate(
            current: current,
            installed: installed,
            trustEvaluationPassed: isTrusted
        )
    }

    private static func validityDates(of certificate: SecCertificate) throws -> (notBefore: Date, notAfter: Date) {
        let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
        var copiedError: Unmanaged<CFError>?
        guard let values = SecCertificateCopyValues(certificate, keys, &copiedError) as NSDictionary? else {
            throw TrustEvaluatorError.certificateValues(copiedError?.takeRetainedValue())
        }
        guard let notBefore = date(for: kSecOIDX509V1ValidityNotBefore, in: values),
              let notAfter = date(for: kSecOIDX509V1ValidityNotAfter, in: values)
        else {
            throw TrustEvaluatorError.missingValidity
        }
        return (notBefore, notAfter)
    }

    private static func date(for key: CFString, in values: NSDictionary) -> Date? {
        let property = values[key] as? NSDictionary
        return property?[kSecPropertyKeyValue] as? Date
    }
}

private enum TrustEvaluatorError: LocalizedError {
    case certificateValues(CFError?)
    case createTrust(OSStatus)
    case invalidKeychainResult
    case invalidPEM
    case keychain(OSStatus)
    case missingCommonName
    case missingValidity

    var errorDescription: String? {
        switch self {
        case .certificateValues:
            "macOS could not read the Localfox certificate. Regenerate the certificate, then try again."
        case .createTrust:
            "macOS could not create a certificate trust check. Reinstall the Localfox certificate, then try again."
        case .invalidKeychainResult:
            "macOS returned an unexpected certificate list. Reopen Localfox, then try again."
        case .invalidPEM:
            "The helper returned an invalid certificate. Restart the proxy to regenerate it, then try again."
        case .keychain:
            "Localfox could not read certificates from the keychain. Unlock the keychain, then try again."
        case .missingCommonName, .missingValidity:
            "The Localfox certificate is missing required identity information. Regenerate it, then try again."
        }
    }
}
