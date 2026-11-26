import Darwin
import Foundation

/// A socket a spawned dev server is listening on.
public struct DiscoveredListener: Hashable, Sendable {
    public let pid: pid_t
    public let port: Int
    public let family: ListeningSocket.AddressFamily
    /// `127.0.0.1` and `::1` are loopback. `0.0.0.0` and `::` mean the server
    /// bound every interface and is already reachable from the LAN, which
    /// Localfox reports rather than silently claiming otherwise.
    public let bindsAllInterfaces: Bool
}

/// Finds the port a spawned process tree actually bound.
///
/// Runtime discovery is authoritative. A framework default is only ever a hint,
/// because a dev server whose preferred port is taken quietly moves to the next
/// one and the whole point of Localfox is that the domain does not follow it.
public struct PortDiscovery: Sendable {
    public init() {}

    /// Every listening TCP socket owned by a process in `group`.
    ///
    /// Membership is by process group, not `proc_listchildpids`. A child walk
    /// only sees direct children, so when `pnpm` execs and exits, the real
    /// `node` reparents to launchd and disappears from it. A process group
    /// survives reparenting, and nothing in the pnpm/npm/bun/node chain calls
    /// `setpgid`.
    public func listeners(inGroup group: pid_t) -> [DiscoveredListener] {
        var found: [DiscoveredListener] = []
        for pid in Self.pids(inGroup: group) {
            found.append(contentsOf: Self.listeners(ofProcess: pid))
        }
        return found
    }

    static func pids(inGroup group: pid_t) -> [pid_t] {
        var count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        // The set can grow between sizing and reading, so ask for headroom.
        let capacity = Int(count) / MemoryLayout<pid_t>.size + 64
        var buffer = [pid_t](repeating: 0, count: capacity)
        count = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0, &buffer, Int32(capacity * MemoryLayout<pid_t>.size)
        )
        guard count > 0 else { return [] }

        let live = buffer.prefix(Int(count) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
        return live.filter { pid in
            var info = proc_bsdinfo()
            let size = proc_pidinfo(
                pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)
            )
            guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { return false }
            return pid_t(info.pbi_pgid) == group
        }
    }

    static func listeners(ofProcess pid: pid_t) -> [DiscoveredListener] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }

        let capacity = Int(size) / MemoryLayout<proc_fdinfo>.stride + 16
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let read = proc_pidinfo(
            pid, PROC_PIDLISTFDS, 0, &descriptors,
            Int32(capacity * MemoryLayout<proc_fdinfo>.stride)
        )
        guard read > 0 else { return [] }

        var found: [DiscoveredListener] = []
        for descriptor in descriptors.prefix(Int(read) / MemoryLayout<proc_fdinfo>.stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let got = proc_pidfdinfo(
                pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO,
                &info, Int32(MemoryLayout<socket_fdinfo>.size)
            )
            guard got == Int32(MemoryLayout<socket_fdinfo>.size) else { continue }
            guard info.psi.soi_kind == SOCKINFO_TCP else { continue }
            guard info.psi.soi_proto.pri_tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }

            let internetInfo = info.psi.soi_proto.pri_tcp.tcpsi_ini
            // insi_lport is stored in network byte order inside an Int32.
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: internetInfo.insi_lport)))
            guard port > 0 else { continue }

            let isIPv6 = (internetInfo.insi_vflag & UInt8(INI_IPV6)) != 0
            let wildcard = Self.isWildcard(internetInfo, isIPv6: isIPv6)
            guard wildcard || Self.isLoopback(internetInfo, isIPv6: isIPv6) else { continue }
            found.append(DiscoveredListener(
                pid: pid,
                port: port,
                family: isIPv6 ? .ipv6 : .ipv4,
                bindsAllInterfaces: wildcard
            ))
        }
        return found
    }

    private static func isWildcard(_ info: in_sockinfo, isIPv6: Bool) -> Bool {
        if isIPv6 {
            let address = info.insi_laddr.ina_6
            return withUnsafeBytes(of: address) { $0.allSatisfy { $0 == 0 } }
        }
        return info.insi_laddr.ina_46.i46a_addr4.s_addr == 0
    }

    private static func isLoopback(_ info: in_sockinfo, isIPv6: Bool) -> Bool {
        if isIPv6 {
            return withUnsafeBytes(of: info.insi_laddr.ina_6) { bytes in
                bytes.last == 1 && bytes.dropLast().allSatisfy { $0 == 0 }
            }
        }
        return info.insi_laddr.ina_46.i46a_addr4.s_addr == in_addr_t(INADDR_LOOPBACK).bigEndian
    }

    // MARK: - Choosing

    /// Ports a dev server exposes that are never the one to proxy.
    static let debuggerPorts: Set<Int> = [9229, 9230, 5858]
    /// Vite's default HMR socket when it is split from the main server.
    static let viteHMRPort = 24678
    static let ephemeralFloor = 49152

    /// Ranks candidates so the dev server wins over its debugger and its HMR
    /// socket. A Next.js tree routinely exposes three or four listeners.
    public static func score(_ listener: DiscoveredListener, expected: Int?) -> Int {
        var score = 0
        if let expected {
            if listener.port == expected {
                score += 100
            } else if (expected...(expected + 20)).contains(listener.port) {
                // "3000 was taken, so it took 3001" is the common case.
                score += 60
            }
        }
        if listener.port < ephemeralFloor { score += 20 }
        if debuggerPorts.contains(listener.port) { score -= 200 }
        if listener.port == viteHMRPort { score -= 50 }
        return score
    }

    public static func best(of listeners: [DiscoveredListener], expected: Int?) -> DiscoveredListener? {
        ranked(listeners, expected: expected).first
    }

    private static func ranked(_ listeners: [DiscoveredListener], expected: Int?) -> [DiscoveredListener] {
        listeners.filter { Service.isRoutablePort($0.port) && !debuggerPorts.contains($0.port) }.sorted { lhs, rhs in
            let left = score(lhs, expected: expected)
            let right = score(rhs, expected: expected)
            if left != right { return left > right }
            if lhs.port != rhs.port { return lhs.port < rhs.port }
            return lhs.family == .ipv4 && rhs.family == .ipv6
        }
    }

    // MARK: - Waiting

    public enum DiscoveryFailure: Error, Equatable, Sendable, LocalizedError {
        case timedOut(seconds: Int)
        case processExited

        public var errorDescription: String? {
            switch self {
            case let .timedOut(seconds):
                """
                No listening port appeared within \(seconds) seconds. The server may \
                still be starting, or it may not be an HTTP server. Set the port by \
                hand if Localfox cannot find it.
                """
            case .processExited:
                "The process exited before it opened a port."
            }
        }
    }

    /// Polls until the same port is seen twice in a row, then confirms it.
    ///
    /// Twice in a row because dev servers bind, release and rebind during
    /// startup, and acting on the first sighting points the proxy at a socket
    /// that is about to close.
    public func waitForPort(
        group: pid_t,
        expected: Int?,
        timeout: Duration? = .seconds(30),
        interval: Duration = .milliseconds(250),
        confirm: @Sendable (DiscoveredListener) async -> Bool = { _ in true }
    ) async throws -> DiscoveredListener {
        let deadline = timeout.map { ContinuousClock.now.advanced(by: $0) }
        var previous: Set<DiscoveredListener> = []
        while true {
            try Task.checkCancellation()
            if let deadline, let timeout, ContinuousClock.now >= deadline {
                throw DiscoveryFailure.timedOut(seconds: Int(timeout.components.seconds))
            }
            guard ProcessSpawner.isAlive(group) else { throw DiscoveryFailure.processExited }
            let candidates = Self.ranked(listeners(inGroup: group), expected: expected)
            for candidate in candidates where previous.contains(candidate) {
                try Task.checkCancellation()
                if await confirm(candidate) {
                    try Task.checkCancellation()
                    return candidate
                }
            }
            previous = Set(candidates)
            try await Task.sleep(for: interval)
        }
    }

    /// Keep a cold build alive and back off the poll when it takes longer than a normal startup.
    public func waitForHTTP(
        group: pid_t, expected: Int?, host: String,
        slowAfter: Duration = .seconds(30), onSlowStart: @Sendable () async -> Void
    ) async throws -> DiscoveredListener {
        do {
            return try await waitForPort(group: group, expected: expected, timeout: slowAfter) {
                await Self.confirmHTTP($0, host: host)
            }
        } catch DiscoveryFailure.timedOut {
            try Task.checkCancellation()
            await onSlowStart()
            return try await waitForPort(group: group, expected: expected, timeout: nil, interval: .seconds(1)) {
                await Self.answersHTTP(port: $0.port, family: $0.family, host: host, timeout: .seconds(15))
            }
        }
    }

    /// Confirms a candidate really is a web server.
    ///
    /// A listening socket alone proves nothing: a stray database client or an
    /// inspector also listens. Any HTTP-shaped answer, including a 404 or a 500,
    /// settles it, so only a confirmed port is ever pushed to the proxy.
    public static func confirmHTTP(_ listener: DiscoveredListener, host: String) async -> Bool {
        await answersHTTP(port: listener.port, family: listener.family, host: host)
    }

    public static func answersHTTP(
        port: Int, family: ListeningSocket.AddressFamily = .ipv4, host: String? = nil,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        guard let url = URL(string: "http://\(family.loopbackHost):\(port)/") else { return false }
        return await HTTPProbe(timeout: timeout).answersHTTP(at: url, host: host)
    }
}
