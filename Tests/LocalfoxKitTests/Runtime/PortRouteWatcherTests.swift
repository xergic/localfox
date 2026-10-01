import Foundation
import Synchronization
import Testing
@testable import LocalfoxKit

private final class Recorder: Sendable {
    private let statuses = Mutex<[ServiceStatus]>([])

    /// Drains the watcher's stream for the life of the test.
    init(_ watcher: PortRouteWatcher) {
        let events = watcher.events
        Task {
            for await event in events { self.statuses.withLock { $0.append(event.status) } }
        }
    }

    var all: [ServiceStatus] { statuses.withLock { $0 } }

    func waitUntil(_ condition: @escaping ([ServiceStatus]) -> Bool) async throws {
        for _ in 0..<200 {
            if condition(all) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out, saw \(all)")
    }
}

@Suite("watching a port route")
struct PortRouteWatcherTests {
    private let port = 8081

    @Test("follows the port open and closed, reporting each change once")
    func followsThePort() async throws {
        let open = Mutex(false)
        let watcher = PortRouteWatcher(interval: .milliseconds(10), probe: { _ in open.withLock { $0 } })
        let recorder = Recorder(watcher)
        let id = UUID()
        await watcher.start(id: id, port: port)
        try await recorder.waitUntil { $0.last == .waiting(port: 8081) }
        try await Task.sleep(for: .milliseconds(50))
        open.withLock { $0 = true }
        try await recorder.waitUntil { $0.last == .running(pid: nil, port: 8081) }
        open.withLock { $0 = false }
        try await recorder.waitUntil { $0.count == 4 }
        #expect(recorder.all == [.starting, .waiting(port: 8081), .running(pid: nil, port: 8081), .waiting(port: 8081)])
        await watcher.stop(id: id)
    }

    @Test("a probe that finishes after stop never reports")
    func stopWinsOverInFlightProbe() async throws {
        let release = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let watcher = PortRouteWatcher(
            interval: .milliseconds(10),
            probe: { _ in
                await withCheckedContinuation { continuation in release.withLock { $0 = continuation } }
                return true
            }
        )
        let recorder = Recorder(watcher)
        let id = UUID()
        await watcher.start(id: id, port: port)
        for _ in 0..<200 where release.withLock({ $0 == nil }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(release.withLock { $0 != nil }, "the probe never parked")
        await watcher.stop(id: id)
        release.withLock { $0?.resume(); $0 = nil }
        try await recorder.waitUntil { $0.last == .stopped }
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.all == [.starting, .stopped])
        #expect(await !watcher.isWatching(id))
    }

    @Test("starting twice keeps one watch")
    func startIsIdempotent() async throws {
        let watcher = PortRouteWatcher(interval: .milliseconds(10), probe: { _ in false })
        let recorder = Recorder(watcher)
        let id = UUID()
        await watcher.start(id: id, port: port)
        await watcher.start(id: id, port: port)
        try await recorder.waitUntil { $0.contains(.waiting(port: 8081)) }
        #expect(recorder.all.filter { $0 == .starting }.count == 1)
        await watcher.stopAll()
        try await recorder.waitUntil { $0.last == .stopped }
    }
}
