import Darwin
import Foundation
import LocalfoxKit
import Security

final class HelperService: NSObject, NSXPCListenerDelegate, LocalfoxHelperProtocol, @unchecked Sendable {
    private let runtime = HelperRuntime()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard let auditToken = Self.auditToken(for: connection) else { return false }
        let auditData = withUnsafeBytes(of: auditToken) { Data($0) }
        let attributes = [kSecGuestAttributeAudit as String: auditData] as CFDictionary

        var guestCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guestCode) == errSecSuccess,
              let guestCode
        else { return false }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            HelperIdentity.clientRequirement as CFString,
            [],
            &requirement
        ) == errSecSuccess, let requirement else { return false }

        guard SecCodeCheckValidity(guestCode, [], requirement) == errSecSuccess else { return false }

        // Exporting even the interface before this check would let any local
        // process invoke a root service and turn the Mach service into an LPE.
        connection.exportedInterface = NSXPCInterface(with: LocalfoxHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func ping(reply: @escaping (String, Bool) -> Void) {
        let reply = XPCReply(reply)
        Task {
            let running = await runtime.isRunning()
            reply.call(Self.version, running)
        }
    }

    func setRoutes(_ routes: Data, reply: @escaping (String?) -> Void) {
        let decodedRoutes: [ProxyRoute]
        do {
            decodedRoutes = try JSONDecoder().decode([ProxyRoute].self, from: routes)
        } catch {
            reply("Invalid proxy routes: \(error.localizedDescription)")
            return
        }

        let reply = XPCReply(reply)
        Task {
            do {
                try await runtime.setRoutes(decodedRoutes)
                reply.call(nil)
            } catch {
                reply.call(Self.message(for: error))
            }
        }
    }

    func setUpstream(routeID: String, port: Int, reply: @escaping (String?) -> Void) {
        guard HelperRequestValidator.isValidRouteID(routeID) else {
            reply("The route ID must match ^[A-Za-z0-9_-]{1,32}$.")
            return
        }
        guard ProxyRoute.isValidPort(port) else {
            reply("The upstream port must be between 1 and 65535.")
            return
        }

        let reply = XPCReply(reply)
        Task {
            do {
                try await runtime.setUpstream(routeID: routeID, port: port)
                reply.call(nil)
            } catch {
                reply.call(Self.message(for: error))
            }
        }
    }

    func stopProxy(reply: @escaping (String?) -> Void) {
        let reply = XPCReply(reply)
        Task {
            await runtime.stopProxy()
            reply.call(nil)
        }
    }

    func exportRootCA(reply: @escaping (Data?, String?) -> Void) {
        let reply = XPCReply(reply)
        Task {
            do {
                reply.call(try await runtime.exportRootCA(), nil)
            } catch {
                reply.call(nil, Self.message(for: error))
            }
        }
    }

    func installRootCATrust(reply: @escaping (String?) -> Void) {
        let reply = XPCReply(reply)
        Task {
            do {
                try await runtime.installRootCATrust()
                reply.call(nil)
            } catch {
                reply.call(Self.message(for: error))
            }
        }
    }

    func removeRootCATrust(sha256Hex: String, reply: @escaping (String?) -> Void) {
        guard HelperRequestValidator.isValidFingerprint(sha256Hex) else {
            reply("The certificate fingerprint must be exactly 64 hexadecimal characters.")
            return
        }

        let reply = XPCReply(reply)
        Task {
            do {
                try await runtime.removeRootCATrust(sha256Hex: sha256Hex)
                reply.call(nil)
            } catch {
                reply.call(Self.message(for: error))
            }
        }
    }

    func caddyLog(lines: Int, reply: @escaping (String) -> Void) {
        let clampedLines = HelperRequestValidator.clampLogLines(lines)
        let reply = XPCReply(reply)
        Task {
            reply.call(await runtime.caddyLog(lines: clampedLines))
        }
    }

    func shutDown() async {
        await runtime.stopProxy()
    }

    static func cleanUpOrphanedCaddy() {
        CaddyProcessControl.cleanUpOrphan()
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    /// Foundation exposes this Objective-C property to KVC but not to Swift.
    /// The token comes from the kernel with the accepted Mach message, avoiding
    /// the PID-reuse race inherent in checking `processIdentifier` instead.
    private static func auditToken(for connection: NSXPCConnection) -> audit_token_t? {
        let rawValue = connection.value(forKey: "auditToken")
        var token = audit_token_t()

        if let value = rawValue as? NSValue {
            withUnsafeMutableBytes(of: &token) { bytes in
                guard let address = bytes.baseAddress else { return }
                value.getValue(address, size: bytes.count)
            }
            return token
        }
        if let data = rawValue as? Data, data.count == MemoryLayout<audit_token_t>.size {
            _ = withUnsafeMutableBytes(of: &token) { bytes in
                data.copyBytes(to: bytes)
            }
            return token
        }
        return nil
    }

    private static func message(for error: any Error) -> String {
        if let localizedError = error as? any LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

private final class XPCReply<Reply>: @unchecked Sendable {
    let call: Reply

    init(_ call: Reply) {
        self.call = call
    }
}

private actor HelperRuntime {
    private let layout = CaddyLayout.production()
    private let supervisor: CaddySupervisor
    private let adminClient: CaddyAdminClient
    private let trustStore: TrustStore
    private var caddy: ManagedCaddy?

    init() {
        let layout = CaddyLayout.production()
        self.supervisor = CaddySupervisor(layout: layout)
        self.adminClient = CaddyAdminClient(socketPath: layout.adminSocket.path)
        self.trustStore = TrustStore(rootCertificate: HelperPaths.rootCertificate)
    }

    func isRunning() -> Bool {
        guard let caddy else { return false }
        return CaddyProcessControl.isVerified(caddy.record)
    }

    func setRoutes(_ routes: [ProxyRoute]) async throws {
        let options = CaddyConfigBuilder.Options(
            storageRoot: layout.storageRoot.path,
            logPath: layout.logFile.path,
            adminSocketPath: layout.adminSocket.path,
            caID: HelperPaths.caID,
            caName: "Localfox Local Authority"
        )
        let config = try CaddyConfigBuilder(options: options).build(routes: routes)

        if isRunning() {
            try await adminClient.load(config: config)
            return
        }

        caddy = nil
        try? FileManager.default.removeItem(at: HelperPaths.pidFile)
        let process = try await supervisor.start(configJSON: config, httpPort: 80, httpsPort: 443)
        guard let snapshot = ProcessInspector().snapshot(pid: process.pid),
              snapshot.executableName == "caddy",
              let executablePath = snapshot.resolvedExecutablePath
        else {
            throw HelperRuntimeError.couldNotVerifyCaddy
        }

        let record = CaddyPIDRecord(
            pid: process.pid,
            identity: snapshot.identity,
            executablePath: executablePath
        )
        do {
            try CaddyProcessControl.write(record)
        } catch {
            await CaddyProcessControl.stop(record)
            throw error
        }
        caddy = ManagedCaddy(process: process, record: record)
    }

    func setUpstream(routeID: String, port: Int) async throws {
        guard isRunning() else { throw HelperRuntimeError.caddyIsNotRunning }
        let path = "/id/svc-\(routeID)-upstream"
        let body = try CaddyConfigBuilder.upstreamPatchBody(port: port)
        try await adminClient.patch(path: path, body: body)
    }

    func stopProxy() async {
        if let caddy {
            await CaddyProcessControl.stop(caddy.record)
        }
        caddy = nil
        try? FileManager.default.removeItem(at: layout.adminSocket)
        try? FileManager.default.removeItem(at: HelperPaths.pidFile)
    }

    func exportRootCA() async throws -> Data {
        do {
            let response = try await adminClient.rootCA(id: HelperPaths.caID)
            return try JSONDecoder().decode(RootCAResponse.self, from: response).pemData
        } catch {
            return try trustStore.readRootCertificate()
        }
    }

    func installRootCATrust() throws {
        try trustStore.installRootCertificate()
    }

    func removeRootCATrust(sha256Hex: String) throws {
        try trustStore.removeRootCertificate(sha256Hex: sha256Hex)
    }

    func caddyLog(lines: Int) -> String {
        guard lines > 0,
              let handle = try? FileHandle(forReadingFrom: layout.logFile)
        else { return "" }
        defer { try? handle.close() }

        do {
            let end = try handle.seekToEnd()
            let maximumBytes: UInt64 = 4 * 1_024 * 1_024
            let start = end > maximumBytes ? end - maximumBytes : 0
            try handle.seek(toOffset: start)
            guard let data = try handle.readToEnd() else { return "" }
            var logLines = String(decoding: data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false)
            if start > 0, !logLines.isEmpty { logLines.removeFirst() }
            if logLines.last?.isEmpty == true { logLines.removeLast() }
            return logLines.suffix(lines).joined(separator: "\n")
        } catch {
            return "Could not read the Caddy log: \(error.localizedDescription)"
        }
    }
}

private struct RootCAResponse: Decodable {
    let rootCertificate: String

    var pemData: Data { Data(rootCertificate.utf8) }

    private enum CodingKeys: String, CodingKey {
        case rootCertificate = "root_certificate"
    }
}

private struct ManagedCaddy: Sendable {
    let process: SpawnedProcess
    let record: CaddyPIDRecord
}

private struct CaddyPIDRecord: Codable, Sendable {
    let pid: pid_t
    let identity: String
    let executablePath: String
}

private enum HelperPaths {
    static let caID = "localfox"
    static let pidFile = URL(fileURLWithPath: "/var/run/localfox/caddy.pid")
    static let rootCertificate = CaddyLayout.production().storageRoot
        .appendingPathComponent("pki/authorities/\(caID)/root.crt")
}

private enum HelperRuntimeError: LocalizedError {
    case caddyIsNotRunning
    case couldNotVerifyCaddy

    var errorDescription: String? {
        switch self {
        case .caddyIsNotRunning:
            "Caddy is not running. Set the routes before changing an upstream."
        case .couldNotVerifyCaddy:
            "Caddy started, but the helper could not verify its process identity."
        }
    }
}

private enum CaddyProcessControl {
    static func write(_ record: CaddyPIDRecord) throws {
        let directory = HelperPaths.pidFile.deletingLastPathComponent()
        try prepareRuntimeDirectory(directory)
        let data = try JSONEncoder().encode(record)
        try data.write(to: HelperPaths.pidFile, options: .atomic)
    }

    /// Creates the runtime directory owned by root and readable by nobody else.
    ///
    /// `/var/run` is `root:daemon` with group write, so only root can create
    /// entries there today. Even so, a directory this daemon writes into as root
    /// is not left to the default mode, and a pre-existing symlink is refused
    /// rather than followed, because following one would redirect a privileged
    /// write to wherever it points.
    static func prepareRuntimeDirectory(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path)
            if attributes?[.type] as? FileAttributeType == .typeSymbolicLink || !isDirectory.boolValue {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            return
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    static func cleanUpOrphan() {
        defer {
            try? FileManager.default.removeItem(at: HelperPaths.pidFile)
        }
        guard let data = try? Data(contentsOf: HelperPaths.pidFile),
              let record = try? JSONDecoder().decode(CaddyPIDRecord.self, from: data),
              isVerified(record)
        else { return }
        defer {
            try? FileManager.default.removeItem(at: CaddyLayout.production().adminSocket)
        }

        for signal in [SIGINT, SIGTERM, SIGKILL] {
            guard isVerified(record) else { return }
            kill(-record.pid, signal)
            if waitSynchronouslyForExit(record, seconds: signal == SIGINT ? 2 : 3) { return }
        }
    }

    static func stop(_ record: CaddyPIDRecord) async {
        for (signal, grace) in [(SIGINT, 1.5), (SIGTERM, 3.0), (SIGKILL, 2.0)] {
            guard isVerified(record) else { return }
            kill(-record.pid, signal)
            if await waitForExit(record, seconds: grace) { return }
        }
    }

    static func isVerified(_ record: CaddyPIDRecord) -> Bool {
        guard record.pid > 1,
              record.pid != getpgrp(),
              getpgid(record.pid) == record.pid,
              let snapshot = ProcessInspector().snapshot(pid: record.pid)
        else { return false }
        return snapshot.identity == record.identity
            && snapshot.executableName == "caddy"
            && snapshot.resolvedExecutablePath == record.executablePath
    }

    private static func waitSynchronouslyForExit(_ record: CaddyPIDRecord, seconds: Int) -> Bool {
        for _ in 0..<(seconds * 20) {
            if !isVerified(record) { return true }
            usleep(50_000)
        }
        return !isVerified(record)
    }

    private static func waitForExit(_ record: CaddyPIDRecord, seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if !isVerified(record) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !isVerified(record)
    }
}
