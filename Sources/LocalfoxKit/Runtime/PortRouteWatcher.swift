import Foundation

public struct PortRouteEvent: Hashable, Sendable {
    public let id: UUID
    public let status: ServiceStatus
}

/// Follows the ports of started port routes.
///
/// A route has no process to wait on, so "running" means only that the port
/// accepts connections right now. Docker restarts and dropped SSH forwards
/// close it and open it again, which is why this keeps polling after the
/// first success instead of confirming once the way `PortDiscovery` does.
public actor PortRouteWatcher {
    public typealias Probe = @Sendable (Int) async -> Bool

    /// Detached, because `PortProbe` blocks for up to its timeout and the
    /// cooperative pool should not wait on a socket.
    public static let loopbackProbe: Probe = { port in
        await Task.detached { PortProbe.accepts(port: port) }.value
    }

    /// One ordered stream rather than a callback per event. A callback that
    /// hops to the main actor in its own task can land `.running` after
    /// `.stopped`, and that order is what decides whether a route exists.
    public nonisolated let events: AsyncStream<PortRouteEvent>
    private let continuation: AsyncStream<PortRouteEvent>.Continuation

    private struct Watch {
        let generation: Int
        let task: Task<Void, Never>
    }

    private var watches: [UUID: Watch] = [:]
    private var generation = 0
    private let interval: Duration
    private let probe: Probe

    public init(interval: Duration = .seconds(2), probe: @escaping Probe = PortRouteWatcher.loopbackProbe) {
        self.interval = interval
        self.probe = probe
        (events, continuation) = AsyncStream.makeStream()
    }

    deinit { continuation.finish() }

    public func isWatching(_ id: UUID) -> Bool { watches[id] != nil }

    public func start(id: UUID, port: Int) {
        guard watches[id] == nil else { return }
        generation += 1
        let current = generation
        emit(.starting, for: id)
        let task = Task { [weak self, interval, probe] in
            var last: ServiceStatus = .starting
            while !Task.isCancelled {
                let next: ServiceStatus = await probe(port)
                    ? .running(pid: nil, port: port)
                    : .waiting(port: port)
                if next != last {
                    guard await self?.report(next, for: id, generation: current) == true else { return }
                    last = next
                }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
        watches[id] = Watch(generation: current, task: task)
    }

    /// Checked on the actor, after the probe's await. A probe in flight when
    /// `stop` ran would otherwise report `.running` after `.stopped`.
    private func report(_ status: ServiceStatus, for id: UUID, generation: Int) -> Bool {
        guard watches[id]?.generation == generation else { return false }
        emit(status, for: id)
        return true
    }

    private func emit(_ status: ServiceStatus, for id: UUID) {
        continuation.yield(PortRouteEvent(id: id, status: status))
    }

    public func stop(id: UUID) {
        guard let watch = watches.removeValue(forKey: id) else { return }
        watch.task.cancel()
        emit(.stopped, for: id)
    }

    public func stopAll() {
        for id in Array(watches.keys) { stop(id: id) }
    }
}
