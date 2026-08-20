import Foundation
import LocalfoxKit

struct TrustStore: Sendable {
    private static let securityTool = URL(fileURLWithPath: "/usr/bin/security")
    private static let systemKeychain = "/Library/Keychains/System.keychain"

    let rootCertificate: URL

    func readRootCertificate() throws -> Data {
        try Data(contentsOf: rootCertificate)
    }

    func installRootCertificate() throws {
        _ = try readRootCertificate()
        try runSecurity([
            "add-trusted-cert",
            "-d",
            "-r", "trustRoot",
            "-p", "ssl",
            "-p", "basic",
            "-k", Self.systemKeychain,
            rootCertificate.path
        ])
    }

    func removeRootCertificate(sha256Hex: String) throws {
        guard HelperRequestValidator.isValidFingerprint(sha256Hex) else {
            throw TrustStoreError.invalidFingerprint
        }
        try runSecurity([
            "delete-certificate",
            "-Z", sha256Hex,
            Self.systemKeychain
        ])
    }

    private func runSecurity(_ arguments: [String]) throws {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = Self.securityTool
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw TrustStoreError.couldNotRun(error.localizedDescription)
        }
        process.waitUntilExit()

        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw TrustStoreError.securityFailed(
                status: process.terminationStatus,
                message: message.isEmpty ? "security produced no error text" : message
            )
        }
    }
}

private enum TrustStoreError: LocalizedError {
    case invalidFingerprint
    case couldNotRun(String)
    case securityFailed(status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidFingerprint:
            "The certificate fingerprint must be exactly 64 hexadecimal characters."
        case let .couldNotRun(message):
            "Could not run /usr/bin/security: \(message)"
        case let .securityFailed(status, message):
            "/usr/bin/security failed with status \(status): \(message)"
        }
    }
}
