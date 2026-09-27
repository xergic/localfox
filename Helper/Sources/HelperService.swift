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

        // Derived from this daemon's own signature, never a constant. The helper
        // and the app ship in one bundle and are signed together, so its own
        // team is exactly the team it should require. An ad hoc build has no
        // team, and rather than fall back to trusting anyone, it refuses every
        // client: a local build simply cannot drive the privileged path.
        guard let team = HelperIdentity.currentTeamIdentifier() else { return false }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            HelperIdentity.clientRequirement(team: team) as CFString,
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

    func setRoutes(_ routes: Data, recordsRequests: Bool, reply: @escaping (String?) -> Void) {
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
                try await runtime.setRoutes(decodedRoutes, recordsRequests: recordsRequests)
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

    func caddyLog(lines: Int, reply: @escaping (String) -> Void) {
        let clampedLines = HelperRequestValidator.clampLogLines(lines)
        let reply = XPCReply(reply)
        Task {
            reply.call(await runtime.caddyLog(lines: clampedLines))
        }
    }

    func accessLog(host: String, lines: Int, reply: @escaping (String) -> Void) {
        guard let marker = HelperRequestValidator.accessLogMarker(host: host) else {
            reply("")
            return
        }
        let clampedLines = HelperRequestValidator.clampLogLines(lines)
        let reply = XPCReply(reply)
        Task {
            reply.call(await runtime.accessLog(matching: marker, lines: clampedLines))
        }
    }

    func shutDown() async {
        await runtime.stopProxy()
    }

    static func cleanUpOrphanedCaddy() {
        CaddyProcessControl.cleanUpOrphan()
    }

    /// The build number of the app bundle this daemon ships inside.
    ///
    /// `Bundle.main` already resolves to the enclosing `.app` for an executable
    /// under `Contents/MacOS`, so there is nothing to walk. The build number
    /// rather than the marketing version, because that is what changes on every
    /// build and so is what tells the app launchd is serving a stale helper.
    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
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
    private var caddy: ManagedCaddy?
    /// The route load in flight, so the next one queues behind it.
    private var routeSync: Task<Void, any Error>?
    /// The ids from the last `setRoutes` call.
    ///
    /// The app owns the whole route table and every sync carries all of it.
    /// `setUpstream` is the one delta, and it exists only so repointing a port
    /// leaves the sibling routes and their cached certificates untouched. That
    /// makes it an optimisation, never a second way to describe the table, so it
    /// must not be able to reach an id the app did not just declare. Without
    /// this the only guard is Caddy answering 404 for an unknown `@id`, which
    /// puts the invariant in a component that knows nothing about it.
    private var declaredRouteIDs: Set<String> = []

    init() {
        let layout = CaddyLayout.production()
        self.supervisor = CaddySupervisor(layout: layout)
        self.adminClient = CaddyAdminClient(socketPath: layout.adminSocket.path)
    }

    func isRunning() -> Bool {
        guard let caddy else { return false }
        return CaddyProcessControl.isVerified(caddy.record)
    }

    /// Applies a route table, one at a time.
    ///
    /// `setRoutes` suspends on the admin API, and this actor lets another call
    /// in while it does. The app syncs from several unstructured tasks, so two
    /// can overlap and complete out of order, leaving `declaredRouteIDs`
    /// describing a different table from the one Caddy is actually serving and
    /// undermining the `setUpstream` check that rests on it. Chaining onto the
    /// previous call makes the load and the record of it one indivisible step.
    func setRoutes(_ routes: [ProxyRoute], recordsRequests: Bool) async throws {
        let previous = routeSync
        let task = Task {
            // The previous sync's failure is its caller's to report, not this
            // one's. Only its ordering matters here.
            _ = try? await previous?.value
            try await applyRoutes(routes, recordsRequests: recordsRequests)
        }
        routeSync = task
        defer { if routeSync == task { routeSync = nil } }
        try await task.value
    }

    private func applyRoutes(_ routes: [ProxyRoute], recordsRequests: Bool) async throws {
        let options = CaddyConfigBuilder.Options(
            storageRoot: layout.storageRoot.path,
            logPath: layout.logFile.path,
            accessLogPath: layout.accessLog.path,
            adminSocketPath: layout.adminSocket.path,
            caID: layout.caID,
            caName: layout.caName
        )
        let config = try CaddyConfigBuilder(options: options)
            .build(routes: routes, recordsRequests: recordsRequests)

        if isRunning() {
            try await adminClient.load(config: config)
            declaredRouteIDs = Set(routes.map(\.id))
            return
        }

        caddy = nil
        try? FileManager.default.removeItem(at: HelperPaths.pidFile)
        let process = try await supervisor.start(
            configJSON: config,
            httpPort: 80,
            httpsPort: 443,
            privileged: true,
            signingTeam: HelperIdentity.currentTeamIdentifier()
        )
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
        declaredRouteIDs = Set(routes.map(\.id))
    }

    func setUpstream(routeID: String, port: Int) async throws {
        guard isRunning() else { throw HelperRuntimeError.caddyIsNotRunning }
        guard declaredRouteIDs.contains(routeID) else {
            throw HelperRuntimeError.undeclaredRoute(routeID)
        }
        let path = "/id/svc-\(routeID)-upstream"
        let body = try CaddyConfigBuilder.upstreamPatchBody(port: port)
        try await adminClient.patch(path: path, body: body)
    }

    func stopProxy() async {
        if let caddy {
            await CaddyProcessControl.stop(caddy.record)
        }
        caddy = nil
        declaredRouteIDs = []
        try? FileManager.default.removeItem(at: layout.adminSocket)
        try? FileManager.default.removeItem(at: HelperPaths.pidFile)
    }

    func exportRootCA() async throws -> Data {
        do {
            let response = try await adminClient.rootCA(id: HelperPaths.caID)
            return try JSONDecoder().decode(RootCAResponse.self, from: response).pemData
        } catch {
            return try Data(contentsOf: HelperPaths.rootCertificate)
        }
    }

    func caddyLog(lines: Int) -> String {
        tail(of: layout.logFile, lines: lines)
    }

    func accessLog(matching marker: String, lines: Int) -> String {
        tail(of: layout.accessLog, lines: lines, matching: marker)
    }

    /// The last `lines` of a log the app cannot open itself.
    ///
    /// Reads backwards in chunks rather than taking a fixed window off the end.
    /// The requests panel asks for this every couple of seconds, and the access
    /// log rolls at 10 MB, so a fixed 4 MB window meant reading, decoding and
    /// splitting four megabytes per tick in the root daemon to keep a few
    /// hundred lines. One chunk usually covers the whole answer.
    ///
    /// - Parameter marker: Keeps only lines containing it. Applied here so a
    ///   line belonging to another service never crosses the boundary at all.
    private func tail(of file: URL, lines: Int, matching marker: String? = nil) -> String {
        guard lines > 0,
              let handle = try? FileHandle(forReadingFrom: file)
        else { return "" }
        defer { try? handle.close() }

        do {
            var end = try handle.seekToEnd()
            var collected: [String] = []
            var carry = ""
            // A ceiling as well as a line count, so a log with one enormous line
            // cannot make this read the whole file.
            var budget = 8 * 1_024 * 1_024

            while end > 0, collected.count < lines, budget > 0 {
                let size = UInt64(min(Int(end), 64 * 1_024))
                end -= size
                budget -= Int(size)
                try handle.seek(toOffset: end)
                guard let data = try handle.read(upToCount: Int(size)) else { break }

                var chunk = String(decoding: data, as: UTF8.self) + carry
                var pieces = chunk.split(separator: "\n", omittingEmptySubsequences: false)
                // The first piece is only a whole line once the read reached the
                // start of the file; before that it is the tail of a line whose
                // head is in the next chunk back.
                carry = end > 0 ? String(pieces.removeFirst()) : ""
                chunk = ""

                for piece in pieces.reversed() where !piece.isEmpty {
                    if let marker, !piece.contains(marker) { continue }
                    collected.append(String(piece))
                    if collected.count == lines { break }
                }
            }
            return collected.reversed().joined(separator: "\n")
        } catch {
            return "Could not read \(file.lastPathComponent): \(error.localizedDescription)"
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
    static let caID = CaddyLayout.production().caID
    static let pidFile = URL(fileURLWithPath: "/var/run/localfox/caddy.pid")
    static let rootCertificate = CaddyLayout.production().rootCertificate
}

private enum HelperRuntimeError: LocalizedError {
    case caddyIsNotRunning
    case couldNotVerifyCaddy
    case undeclaredRoute(String)

    var errorDescription: String? {
        switch self {
        case .caddyIsNotRunning:
            "Caddy is not running. Set the routes before changing an upstream."
        case .couldNotVerifyCaddy:
            "Caddy started, but the helper could not verify its process identity."
        case let .undeclaredRoute(routeID):
            """
            Route \(routeID) is not in the table the helper is serving. \
            Set the full route table before changing an upstream.
            """
        }
    }
}

private enum CaddyProcessControl {
    static func write(_ record: CaddyPIDRecord) throws {
        let directory = HelperPaths.pidFile.deletingLastPathComponent()
        try CaddySupervisor.prepareDirectory(directory, privileged: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: HelperPaths.pidFile, options: .atomic)
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
