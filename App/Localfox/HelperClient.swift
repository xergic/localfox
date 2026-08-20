import Foundation
import LocalfoxKit
import Observation
import ServiceManagement

@MainActor
@Observable
final class HelperClient {
    private(set) var state: HelperState
    private(set) var lastError: String?

    @ObservationIgnored private var connection: ManagedXPCConnection?
    @ObservationIgnored private var connectionID: UUID?

    init() {
        state = Self.registeredState(for: SMAppService.daemon(plistName: HelperIdentity.plistName).status)
    }

    func install() async {
        var failureMessage: String?
        do {
            try service.register()
            assignError(nil)
        } catch where Self.isAlreadyRegistered(error) {
            assignError(nil)
        } catch {
            failureMessage =
                "Localfox could not register its helper. Move Localfox to Applications, then try again. "
                    + error.localizedDescription
            assignError(failureMessage)
        }
        await refresh()
        if let failureMessage { assignError(failureMessage) }
    }

    func uninstall() async {
        var failureMessage: String?
        do {
            try await service.unregister()
            assignError(nil)
        } catch {
            failureMessage =
                "Localfox could not remove its helper. Quit and reopen Localfox, then try again. "
                    + error.localizedDescription
            assignError(failureMessage)
        }
        tearDownConnection()
        await refresh()
        if let failureMessage { assignError(failureMessage) }
    }

    func reinstall() async {
        var failureMessage: String?
        do {
            try await service.unregister()
            tearDownConnection()
            try service.register()
            assignError(nil)
        } catch {
            failureMessage =
                "Localfox could not reinstall its helper. Open Login Items in System Settings, "
                    + "remove any pending Localfox approval, then try again. \(error.localizedDescription)"
            assignError(failureMessage)
        }
        await refresh()
        if let failureMessage { assignError(failureMessage) }
    }

    func openApproval() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func refresh() async {
        switch service.status {
        case .notRegistered, .notFound:
            tearDownConnection()
            assignState(.notRegistered)
        case .requiresApproval:
            tearDownConnection()
            assignState(.requiresApproval)
        case .enabled:
            do {
                let response = try await ping()
                let expectedVersion = Self.appVersion
                guard response.version == expectedVersion else {
                    assignState(.versionMismatch(expected: expectedVersion, found: response.version))
                    return
                }
                assignState(.ready(version: response.version, caddyRunning: response.caddyRunning))
            } catch {
                assignState(.enabledButUnreachable)
            }
        @unknown default:
            tearDownConnection()
            assignState(.notRegistered)
            assignError("macOS returned an unknown helper status. Update macOS, then reopen Localfox.")
        }
    }

    func ping() async throws -> (version: String, caddyRunning: Bool) {
        try await call(operation: "check the helper") { proxy, reply in
            proxy.ping { version, caddyRunning in
                reply.resume(returning: (version, caddyRunning))
            }
        }
    }

    func setRoutes(_ routes: [ProxyRoute]) async throws {
        let encodedRoutes: Data
        do {
            encodedRoutes = try JSONEncoder().encode(routes)
        } catch {
            throw HelperClientError.request(
                "Localfox could not prepare the proxy routes. Remove and re-add the affected service, then try again."
            )
        }

        try await call(operation: "update proxy routes") { proxy, reply in
            proxy.setRoutes(encodedRoutes) { message in
                reply.resumeHelperResult(message)
            }
        }
    }

    func setUpstream(routeID: String, port: Int) async throws {
        try await call(operation: "update the service port") { proxy, reply in
            proxy.setUpstream(routeID: routeID, port: port) { message in
                reply.resumeHelperResult(message)
            }
        }
    }

    func stopProxy() async throws {
        try await call(operation: "stop the HTTPS proxy") { proxy, reply in
            proxy.stopProxy { message in
                reply.resumeHelperResult(message)
            }
        }
    }

    func exportRootCA() async throws -> Data? {
        try await call(operation: "read the Localfox certificate") { proxy, reply in
            proxy.exportRootCA { data, message in
                if let message {
                    reply.resume(throwing: HelperClientError.helper(operation: "read the Localfox certificate", message: message))
                } else {
                    reply.resume(returning: data)
                }
            }
        }
    }

    func installRootCATrust() async throws {
        try await call(operation: "trust the Localfox certificate") { proxy, reply in
            proxy.installRootCATrust { message in
                reply.resumeHelperResult(message)
            }
        }
    }

    func removeRootCATrust(sha256Hex: String) async throws {
        try await call(operation: "remove the old Localfox certificate") { proxy, reply in
            proxy.removeRootCATrust(sha256Hex: sha256Hex) { message in
                reply.resumeHelperResult(message)
            }
        }
    }

    func caddyLog(lines: Int) async throws -> String {
        try await call(operation: "read the proxy log") { proxy, reply in
            proxy.caddyLog(lines: lines) { log in
                reply.resume(returning: log)
            }
        }
    }

    func disconnect() {
        tearDownConnection()
    }

    private var service: SMAppService {
        SMAppService.daemon(plistName: HelperIdentity.plistName)
    }

    private func call<Value>(
        operation: String,
        invoke: (LocalfoxHelperProtocol, OneShotContinuation<Value>) -> Void
    ) async throws -> Value {
        do {
            let value: Value = try await withCheckedThrowingContinuation { continuation in
                let reply = OneShotContinuation(continuation, operation: operation)
                let proxyObject = activeConnection.remoteObjectProxyWithErrorHandler { error in
                    reply.resume(throwing: HelperClientError.transport(operation: operation, underlying: error))
                }
                guard let proxy = proxyObject as? LocalfoxHelperProtocol else {
                    reply.resume(throwing: HelperClientError.invalidProxy(operation: operation))
                    return
                }
                invoke(proxy, reply)
            }
            assignError(nil)
            return value
        } catch {
            assignError(Self.message(for: error))
            throw error
        }
    }

    private var activeConnection: NSXPCConnection {
        if let connection { return connection.value }

        let xpcConnection = NSXPCConnection(
            machServiceName: HelperIdentity.machServiceName,
            options: .privileged
        )
        let id = UUID()
        xpcConnection.remoteObjectInterface = NSXPCInterface(with: LocalfoxHelperProtocol.self)
        xpcConnection.invalidationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.connectionEnded(id: id, wasInterrupted: false)
            }
        }
        xpcConnection.interruptionHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.connectionEnded(id: id, wasInterrupted: true)
            }
        }
        xpcConnection.resume()
        connection = ManagedXPCConnection(xpcConnection)
        connectionID = id
        return xpcConnection
    }

    private func connectionEnded(id: UUID, wasInterrupted: Bool) {
        guard connectionID == id else { return }
        connection?.value.invalidationHandler = nil
        connection?.value.interruptionHandler = nil
        if wasInterrupted {
            connection?.value.invalidate()
        }
        connection = nil
        connectionID = nil
        if service.status == .enabled {
            assignState(.enabledButUnreachable)
            assignError(
                "The privileged helper stopped responding. Reinstall the helper, then approve Localfox "
                    + "in Login Items if macOS asks."
            )
        }
    }

    private func tearDownConnection() {
        connection?.value.invalidationHandler = nil
        connection?.value.interruptionHandler = nil
        connection?.value.invalidate()
        connection = nil
        connectionID = nil
    }

    private func assignState(_ value: HelperState) {
        guard state != value else { return }
        state = value
    }

    private func assignError(_ value: String?) {
        guard lastError != value else { return }
        lastError = value
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    private static func registeredState(for status: SMAppService.Status) -> HelperState {
        switch status {
        case .notRegistered, .notFound: .notRegistered
        case .requiresApproval: .requiresApproval
        case .enabled: .enabledButUnreachable
        @unknown default: .notRegistered
        }
    }

    private static func isAlreadyRegistered(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == SMAppServiceErrorDomain && error.code == kSMErrorAlreadyRegistered
    }

    private static func message(for error: any Error) -> String {
        if let localizedError = error as? any LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return "Localfox could not contact its privileged helper. Reinstall the helper, then try again."
    }
}

private final class ManagedXPCConnection: @unchecked Sendable {
    let value: NSXPCConnection

    init(_ value: NSXPCConnection) {
        self.value = value
    }

    deinit {
        value.invalidationHandler = nil
        value.interruptionHandler = nil
        value.invalidate()
    }
}

private enum HelperClientError: LocalizedError {
    case helper(operation: String, message: String)
    case invalidProxy(operation: String)
    case request(String)
    case transport(operation: String, underlying: any Error)

    var errorDescription: String? {
        switch self {
        case let .helper(operation, message):
            "The helper could not \(operation): \(message) Check the Localfox diagnostics, then try again."
        case let .invalidProxy(operation):
            "Localfox could not \(operation) because the helper returned an invalid connection. Reinstall the helper, then try again."
        case let .request(message):
            message
        case let .transport(operation, underlying):
            "Localfox could not \(operation) because the privileged helper stopped responding. "
                + "Reinstall the helper, then try again. \(underlying.localizedDescription)"
        }
    }
}

private final class OneShotContinuation<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private let operation: String

    init(_ continuation: CheckedContinuation<Value, any Error>, operation: String) {
        self.continuation = continuation
        self.operation = operation
    }

    func resume(returning value: sending Value) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        take()?.resume(throwing: error)
    }

    func resumeHelperResult(_ message: String?) where Value == Void {
        if let message {
            resume(throwing: HelperClientError.helper(operation: operation, message: message))
        } else {
            resume(returning: ())
        }
    }

    private func take() -> CheckedContinuation<Value, any Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}
