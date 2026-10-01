# Port Routes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user point a stable `https://<name>.localhost` domain at a loopback port that Localfox does not start (Docker, an SSH `-L` forward, a server started in a terminal).

**Architecture:** A `Service` gains a `kind`. A `.portRoute` service has a fixed port and no command. Start begins a watch: a TCP connect to `127.0.0.1:<port>` every 2 s. While it connects, the service is `.running` and gets a proxy route. While it does not, it is `.waiting` and has no route. Stop ends the watch. Routes are created from a new "Route a Port" sheet (standalone, folder optional) or inside the Edit Project sheet.

**Tech Stack:** Swift 6, strict concurrency, SwiftUI, swift-testing, Darwin sockets. No new dependencies.

**Spec:** This conversation's decisions, restated in Global Constraints. No separate spec file.

## Global Constraints

- Entry points: a standalone "Route a Port…" sheet AND "Add Port Route" in Edit Project.
- Lifecycle: Start watches the port, Stop ends the watch. Not restored after relaunch, like every other service.
- Poll interval 2 s. Probe target is `127.0.0.1:<port>` only, because Caddy dials `127.0.0.1:<port>` (`CaddyConfigBuilder.swift:184`).
- Routable ports are 1…65535, minus 80 and 443 (Caddy's own listeners).
- Port routes cannot be shared publicly in this release. No Share UI for them, and `AppState.share*` refuses them.
- `projects.json` moves to format version 2. A version 1 file loads unchanged and every service in it is `.command`.
- The kit never imports SwiftUI or AppKit. `PortProbe` and `PortRouteWatcher` live in the kit so they are testable.
- Do not write to `@Observable` state unless the value moved.
- No comments that restate code. A comment explains a non-obvious why.
- Conventional Commits, one short sentence, no body, no co-author trailer. Work on `main`.
- After every task: `make lint` and `make test`. After UI tasks: `make snapshot` and look at the PNGs.

## Review Focus

1. **Server bound only to `::1`.** The probe fails, the route stays Waiting forever. The Waiting explanation must say the proxy dials `127.0.0.1`. Pinned by the copy test in Task 6 (explanation text) and the `PortProbe` IPv4-only test in Task 3.
2. **Downgrade to 1.2.0 after saving a v2 file.** 1.2.0 refuses the file, shows an empty list, and the next "Add Project" overwrites everything. 1.2.0 cannot be fixed. Task 1 makes this build refuse to save after a failed load, so the next format bump is safe.
3. **Editing a running route's port, or deleting a running route in Edit Project.** The old watch must stop and the proxy must drop the old port. Pinned by `AppState.apply` changes in Task 5 (manual check in Task 8 steps).
4. **Stop pressed while a probe is in flight.** A late `.running` must not land after `.stopped`. Pinned by the generation test in Task 4.
5. **Port 80 or 443 typed in.** Caddy would proxy to itself. Rejected by `Service.isRoutablePort`, pinned in Task 2.

---

### Task 1: Refuse to save over a file that failed to load

**Files:**
- Modify: `Sources/LocalfoxKit/Store/ProjectStore.swift`
- Test: `Tests/LocalfoxKitTests/Store/ProjectStoreTests.swift`

**Interfaces:**
- Produces: `StoreError.refusingToOverwrite(path: String)`. `ProjectStore.save` throws it after any failed `load()`.

- [ ] **Step 1: Write the failing test**

```swift
@Test("a save after a failed load refuses rather than overwriting the file")
func refusesToOverwriteUnreadable() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data(#"{"version":99,"projects":[]}"#.utf8)
    try original.write(to: url)

    let store = ProjectStore(url: url)
    await #expect(throws: StoreError.self) { try await store.load() }
    await #expect(throws: StoreError.refusingToOverwrite(path: url.path)) { try await store.save([]) }
    #expect(try Data(contentsOf: url) == original)
}
```

- [ ] **Step 2: Run it, expect a compile failure** (`refusingToOverwrite` does not exist)

Run: `swift test --filter ProjectStoreTests`

- [ ] **Step 3: Implement**

In `StoreError` add the case and its description:

```swift
case refusingToOverwrite(path: String)
```

```swift
case let .refusingToOverwrite(path):
    """
    Localfox could not read its configuration at \(path), so it will not save \
    over it. Fix or move the file, then relaunch Localfox.
    """
```

In `ProjectStore`, replace the unused `hasLoaded` with `loadFailed`:

```swift
/// Set when `load` threw. Saving after that would replace a file this build
/// could not read with the empty list it fell back to, which is how a
/// downgrade loses every project the newer build wrote.
private var loadFailed = false
```

In `load()`, set `loadFailed = true` before each `throw` (unreadable, malformed, fromTheFuture), and `loadFailed = false` on success. Remove the `hasLoaded` assignments.

At the top of `save(_:)`:

```swift
guard !loadFailed else { throw StoreError.refusingToOverwrite(path: url.path) }
```

- [ ] **Step 4: Run** `swift test --filter ProjectStoreTests`. Expected PASS.
- [ ] **Step 5: Commit** `fix(store): refuse to save over a configuration that failed to load`

---

### Task 2: Model a port route

**Files:**
- Modify: `Sources/LocalfoxKit/Model/Service.swift`
- Modify: `Sources/LocalfoxKit/Store/ProjectStore.swift` (version 2)
- Modify (compile fixes only): `App/Localfox/ServiceRuntime.swift`, `App/Localfox/AppState.swift`, `App/Localfox/AppState+Sharing.swift`, `App/Localfox/ServiceStatusDisplay.swift`, `App/Localfox/Views/*.swift`, `App/Localfox/SnapshotFixture.swift`
- Test: `Tests/LocalfoxKitTests/Store/ProjectStoreTests.swift`, new `Tests/LocalfoxKitTests/Model/PortRouteTests.swift`

**Interfaces:**
- Produces:
  - `enum ServiceKind: String, Codable, Hashable, Sendable { case command, portRoute }`
  - `Service.kind: ServiceKind` (decodes as `.command` when absent)
  - `Service.directory: URL?`, `Project.directory: URL?`, `Project.displayPath: String?`
  - `static func Service.portRoute(name: String, domain: LocalDomain, port: Int, directory: URL?) -> Service?` (nil when the port is not routable)
  - `static func Service.isRoutablePort(_ port: Int) -> Bool`
  - `ServiceStatus.running(pid: pid_t?, port: Int)` (pid nil for a route)
  - `ServiceStatus.waiting(port: Int)`, `ServiceStatus.isActive: Bool` (running or waiting)
  - `StoreDocument.currentVersion == 2`

- [ ] **Step 1: Write the failing tests** in `Tests/LocalfoxKitTests/Model/PortRouteTests.swift`

```swift
import Foundation
import Testing
@testable import LocalfoxKit

@Suite("port routes")
struct PortRouteTests {
    private let domain = LocalDomain("db.localhost")!

    @Test("a route pins its port and runs no command")
    func shape() throws {
        let route = try #require(Service.portRoute(name: "DB", domain: domain, port: 8081, directory: nil))
        #expect(route.kind == .portRoute)
        #expect(route.portMode == .fixed(8081))
        #expect(route.command.isEmpty)
        #expect(route.directory == nil)
    }

    @Test("Caddy's own ports and out of range ports are refused", arguments: [0, 80, 443, 65_536])
    func refusesUnroutable(port: Int) {
        #expect(Service.portRoute(name: "X", domain: domain, port: port, directory: nil) == nil)
    }

    @Test("a service written before kinds existed decodes as a command")
    func legacyDecodesAsCommand() throws {
        let json = #"""
        {"id":"7C8E1B0A-3D7E-4C3B-9C55-0E5F4F0B1A22","name":"Web","directory":"file:///Users/me/web/",
         "framework":"nextJS","command":"pnpm dev","domain":{"value":"web.localhost"},
         "portMode":{"auto":{}},"portFlagStyle":"dashP","environment":{}}
        """#
        let service = try JSONDecoder().decode(Service.self, from: Data(json.utf8))
        #expect(service.kind == .command)
        #expect(service.directory == URL(string: "file:///Users/me/web/"))
    }

    @Test("a route without a fixed port is rejected on decode")
    func routeNeedsFixedPort() throws {
        var route = try #require(Service.portRoute(name: "DB", domain: domain, port: 8081, directory: nil))
        route.portMode = .auto
        let data = try JSONEncoder().encode(route)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Service.self, from: data) }
    }

    @Test("waiting is active but not running and has no proxy port")
    func waitingStatus() {
        let status = ServiceStatus.waiting(port: 8081)
        #expect(status.isActive)
        #expect(!status.isRunning)
        #expect(status.port == nil)
        #expect(!status.isTransitioning)
    }
}
```

Before writing the legacy JSON, confirm the exact encoded shape with a quick `print(String(decoding: try JSONEncoder().encode(service), as: UTF8.self))` in a scratch test and paste the real output, minus `kind`. The synthesized encodings of `URL`, `LocalDomain` and `PortMode` decide it, not this plan.

In `ProjectStoreTests.swift` add:

```swift
@Test("a standalone route with no directory round-trips")
func routeRoundTrips() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let route = try #require(Service.portRoute(name: "Docker", domain: LocalDomain("docker.localhost")!, port: 8081, directory: nil))
    let project = Project(name: "Docker", directory: nil, services: [route])
    try await ProjectStore(url: url).save([project])
    #expect(try await ProjectStore(url: url).load() == [project])
}
```

The existing `writesVersion` test covers the bump to 2.

- [ ] **Step 2: Run** `swift test --filter "PortRouteTests|ProjectStoreTests"`. Expected compile failure.

- [ ] **Step 3: Implement the model** in `Service.swift`

```swift
/// Whether Localfox runs the server or only routes to it.
public enum ServiceKind: String, Hashable, Codable, Sendable {
    /// Localfox spawns `command` and discovers the port it binds.
    case command
    /// Something else serves `portMode`'s fixed port. Localfox only watches
    /// it and routes the domain while it accepts connections.
    case portRoute
}
```

`ServiceStatus`:

```swift
case running(pid: pid_t?, port: Int)
/// A port route whose port is closed. Active, because the user started it
/// and Stop must stay reachable, but routeless: a route to a closed port
/// serves 502s under a domain that looks configured.
case waiting(port: Int)

public var isActive: Bool {
    switch self {
    case .running, .waiting: true
    case .stopped, .starting, .stopping, .failed: false
    }
}
```

Add `.waiting` to the `false` arm of `isTransitioning`. Doc comment on `running`: `pid` is nil for a port route, whose listener Localfox does not own.

`Service`: add `public var kind: ServiceKind`, make `directory: URL?`, add `kind: ServiceKind = .command` as the last init parameter. Add:

```swift
/// 80 and 443 are Caddy's own listeners, so a route there proxies to itself.
public static func isRoutablePort(_ port: Int) -> Bool {
    ProxyRoute.isValidPort(port) && port != 80 && port != 443
}

public static func portRoute(name: String, domain: LocalDomain, port: Int, directory: URL?) -> Service? {
    guard isRoutablePort(port) else { return nil }
    return Service(
        name: name, directory: directory, framework: .unknown, command: "",
        domain: domain, portMode: .fixed(port), kind: .portRoute
    )
}

public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    directory = try container.decodeIfPresent(URL.self, forKey: .directory)
    framework = try container.decode(ServiceType.self, forKey: .framework)
    command = try container.decode(String.self, forKey: .command)
    domain = try container.decode(LocalDomain.self, forKey: .domain)
    portMode = try container.decode(PortMode.self, forKey: .portMode)
    expectedPort = try container.decodeIfPresent(Int.self, forKey: .expectedPort)
    portFlagStyle = try container.decode(PortFlagStyle.self, forKey: .portFlagStyle)
    environment = try container.decode([String: String].self, forKey: .environment)
    // Absent in every file written before routes existed, and all of those were commands.
    kind = try container.decodeIfPresent(ServiceKind.self, forKey: .kind) ?? .command
    if kind == .portRoute, portMode.fixedValue.map(Self.isRoutablePort) != true {
        throw DecodingError.dataCorruptedError(
            forKey: .portMode, in: container,
            debugDescription: "A port route needs a fixed port other than 80 and 443."
        )
    }
}
```

Match the existing non-optional keys exactly. If the synthesized encoder currently omits a nil `expectedPort` and writes `environment` always, keep that.

`Project`: `directory: URL?`. `iconURL` returns nil when `directory` is nil and the path is relative. `iconPathValue(for:)` returns the absolute path when `directory` is nil. `displayPath` becomes `String?`, nil without a directory.

`StoreDocument.currentVersion = 2`, with the comment: `2 added ServiceKind and optional directories. A 1.x build reading a route would treat it as a command with an empty command line, so the bump is what stops it.`

- [ ] **Step 4: Fix the app target so it compiles, with no behaviour change yet**

Every compile error, mechanically:
- `ServiceRuntime.start`: `guard let directory = service.directory else { report .failed(.spawnFailed(errno: ENOENT)) with output "This service has no directory to run in."; return }`, then pass `directory`.
- `AppState+Sharing.share(_:plan:)`: `guard ..., case let .running(pid?, _) = status(of: service)`. The other two `case let .running(_, port)` patterns still compile.
- `ServiceStatusDisplay`: `.waiting` tint `Theme.accentText`, label `"Waiting"`.
- `ServiceDetailPane` PID row: `if case let .running(pid, port) = status { if let pid { PID row } ; Proxying row }`.
- `projectAssets`, `refreshDetectedIcons`: skip a project with no directory (`[]` and no entry).
- `IconPickerView.projectDirectory: URL?`.
- `MenuView` / `EditProjectSheet`: `project.displayPath ?? ""` and `service.directory` reveal buttons wrapped in `if let`. Task 6 replaces these with proper UI.
- `EditProjectSheet.EditableService.directory: URL?`, `suggestDomains` uses `$0.directory?.lastPathComponent ?? $0.name`.
- `SnapshotFixture`: no change needed beyond compiling.

Exhaustive `switch` on `ServiceStatus` elsewhere: the compiler lists them. Treat `.waiting` like `.stopped` for display until Task 6.

- [ ] **Step 5: Run** `make lint && make test && make run`. Expected PASS, and the app launches with existing projects intact.
- [ ] **Step 6: Commit** `feat(kit): model a port route service`

---

### Task 3: Probe a loopback port

**Files:**
- Create: `Sources/LocalfoxKit/Runtime/PortProbe.swift`
- Test: `Tests/LocalfoxKitTests/Runtime/PortProbeTests.swift`

**Interfaces:**
- Produces: `PortProbe.accepts(port: Int, timeout: Duration = .milliseconds(300)) -> Bool`. Synchronous, blocks at most `timeout`.

- [ ] **Step 1: Write the failing test**

```swift
import Darwin
import Foundation
import Testing
@testable import LocalfoxKit

/// A socket listening on a kernel-assigned port, so tests never collide.
private final class Listener {
    let fd: Int32
    let port: Int

    init(family: Int32 = AF_INET) throws {
        // A local, not `self.fd`: the closures below cannot capture `self`
        // before every stored property is set.
        let socketFD = socket(family, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(.EIO) }
        var bound = 0
        if family == AF_INET {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
            try Self.bindAndListen(socketFD, &address)
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(socketFD, $0, &length) }
            }
            bound = Int(UInt16(bigEndian: address.sin_port))
        } else {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_addr = in6addr_loopback
            var only: Int32 = 1
            setsockopt(socketFD, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
            try Self.bindAndListen(socketFD, &address)
            var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(socketFD, $0, &length) }
            }
            bound = Int(UInt16(bigEndian: address.sin6_port))
        }
        fd = socketFD
        port = bound
    }

    private static func bindAndListen<Address>(_ fd: Int32, _ address: inout Address) throws {
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<Address>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
    }

    deinit { close(fd) }
}

@Suite("probing a loopback port")
struct PortProbeTests {
    @Test("an IPv4 loopback listener accepts")
    func acceptsListener() throws {
        let listener = try Listener()
        #expect(PortProbe.accepts(port: listener.port))
    }

    @Test("a closed port does not")
    func refusesClosed() throws {
        let port = try Listener().port
        #expect(!PortProbe.accepts(port: port))
    }

    @Test("a listener on ::1 only is not reachable, because the proxy dials 127.0.0.1")
    func ignoresIPv6Only() throws {
        let listener = try Listener(family: AF_INET6)
        #expect(!PortProbe.accepts(port: listener.port))
    }

    @Test("an invalid port is refused without touching the network", arguments: [0, -1, 70_000])
    func refusesInvalid(port: Int) {
        #expect(!PortProbe.accepts(port: port))
    }
}
```

`refusesClosed` relies on the `Listener` being released at the end of the expression. If that proves flaky, hold it in a variable and close the fd explicitly before probing.

- [ ] **Step 2: Run** `swift test --filter PortProbeTests`. Expected compile failure.

- [ ] **Step 3: Implement** `Sources/LocalfoxKit/Runtime/PortProbe.swift`

```swift
import Darwin

/// Whether something accepts TCP connections on `127.0.0.1:<port>`.
///
/// IPv4 loopback only, because that is the address Caddy dials. A server
/// bound to `::1` alone answers `localhost` in a browser and still 502s
/// behind the proxy, so reporting it as up would be wrong.
///
/// A bare connect rather than `HTTPProbe`: a route can sit in front of
/// anything, and an HTTP request every two seconds would land in the
/// server's own access log.
public enum PortProbe {
    public static func accepts(port: Int, timeout: Duration = .milliseconds(300)) -> Bool {
        guard ProxyRoute.isValidPort(port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let (seconds, attoseconds) = timeout.components
        let milliseconds = Int32(seconds * 1_000 + attoseconds / 1_000_000_000_000_000)
        guard poll(&descriptor, 1, milliseconds) == 1 else { return false }

        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }
}
```

- [ ] **Step 4: Run** `swift test --filter PortProbeTests`. Expected PASS.
- [ ] **Step 5: Commit** `feat(kit): probe whether a loopback port accepts connections`

---

### Task 4: Watch a port route

**Files:**
- Create: `Sources/LocalfoxKit/Runtime/PortRouteWatcher.swift`
- Test: `Tests/LocalfoxKitTests/Runtime/PortRouteWatcherTests.swift`

**Interfaces:**
- Consumes: `PortProbe.accepts(port:timeout:)`, `ServiceStatus.waiting`, `ServiceStatus.running(pid: nil, port:)`.
- Produces:

```swift
public struct PortRouteEvent: Hashable, Sendable {
    public let id: UUID
    public let status: ServiceStatus
}

public actor PortRouteWatcher {
    public typealias Probe = @Sendable (Int) async -> Bool
    public static let loopbackProbe: Probe
    /// Every status change, in the order the actor made it. One consumer.
    public nonisolated let events: AsyncStream<PortRouteEvent>
    public init(interval: Duration = .seconds(2), probe: @escaping Probe = PortRouteWatcher.loopbackProbe)
    public func start(id: UUID, port: Int)
    public func stop(id: UUID)
    public func stopAll()
    public func isWatching(_ id: UUID) -> Bool
}
```

Status sequence: `start` emits `.starting`, then one event per change between `.waiting(port:)` and `.running(pid: nil, port:)`. `stop` emits `.stopped` and nothing for that watch after it.

Why a stream and not an `onStatus` callback like `ServiceRuntime`: a callback that spawns `Task { @MainActor in … }` per event gives no ordering between those tasks. A `.running` spawned just before Stop can land after `.stopped` and push a route for a stopped service. Events yielded from the actor into one `AsyncStream` and read by one loop arrive in order.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Synchronization
import Testing
@testable import LocalfoxKit

private final class Recorder: Sendable {
    private let statuses = Mutex<[ServiceStatus]>([])

    /// Drains the watcher's stream for the life of the test.
    init(_ watcher: PortRouteWatcher) {
        Task { [statuses] in
            for await event in watcher.events { statuses.withLock { $0.append(event.status) } }
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
        try await Task.sleep(for: .milliseconds(30))
        await watcher.stop(id: id)
        release.withLock { $0?.resume(); $0 = nil }
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
```

- [ ] **Step 2: Run** `swift test --filter PortRouteWatcherTests`. Expected compile failure.

- [ ] **Step 3: Implement** `Sources/LocalfoxKit/Runtime/PortRouteWatcher.swift`

```swift
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
```

If `AsyncStream.makeStream()` cannot initialise both `let`s from a tuple in this toolchain, assign through a local pair first.

- [ ] **Step 4: Run** `swift test --filter PortRouteWatcherTests`. Expected PASS. Run it three times to check for flakiness.
- [ ] **Step 5: Commit** `feat(kit): watch a port route's port`

---

### Task 5: Drive routes from AppState

**Files:**
- Modify: `App/Localfox/AppState.swift`, `App/Localfox/AppState+Sharing.swift`

**Interfaces:**
- Consumes: `PortRouteWatcher`, `ServiceKind`, `ServiceStatus.isActive`.
- Produces: `AppState.start/stop/restart/stopEverything/apply` handle both kinds. `AppState.share`, `shareNamed`, `shareSSH` return early for a route.

No unit tests: the app target has none by project rule. Verification is the manual run in Step 3.

- [ ] **Step 1: Implement**

Add `private var routeWatcher: PortRouteWatcher?`, built in `adopt(_:)` next to `tunnelRuntime`, with one consumer loop so events reach `setStatus` in the order the watcher made them:

```swift
let watcher = PortRouteWatcher()
routeWatcher = watcher
Task { [weak self] in
    for await event in watcher.events {
        self?.setStatus(event.status, for: event.id)
    }
}
```

The `Task` inherits `@MainActor` from `AppState`, so `setStatus` runs on the main actor without a hop per event.

`start`:

```swift
func start(_ service: Service) async {
    guard let project = project(owning: service.id) else { return }
    switch service.kind {
    case .command:
        guard let runtime else { return }
        await runtime.start(service, projectName: project.name)
    case .portRoute:
        guard let routeWatcher, let port = service.portMode.fixedValue else { return }
        await routeWatcher.start(id: service.id, port: port)
    }
    Telemetry.send(.serviceStarted)
}
```

`stop`: after `await unshare(service)`, `switch service.kind { case .command: await runtime?.stop(service); case .portRoute: await routeWatcher?.stop(id: service.id) }`.

`restart`: for `.portRoute`, `await stop(service); await start(service)`. Keep the existing path for `.command`.

`stopEverything`: add `await routeWatcher?.stopAll()` after `tunnelRuntime`, then clear the proxy and wait for it. A route's server keeps running after Localfox quits, so a route left in Caddy's table would keep serving the domain with nothing on screen to stop it. `applicationShouldTerminate` already awaits `stopEverything`.

```swift
/// Awaited, unlike the sync `setStatus` schedules, because the app exits
/// right after this returns.
private func clearProxy() async {
    guard helperClient.state.canServe else { return }
    do {
        try await helperClient.setRoutes([], recordsRequests: preferences.recordsRequests)
    } catch {
        assign(\.lastError, error.localizedDescription)
    }
}
```

Call `await clearProxy()` last in `stopEverything`. In `load()`, after `await refreshSetup()`, call `await syncProxy()` once, so a table left by a crash is replaced by the (empty) table this launch owns.

`setStatus`: change the sync condition so leaving `.running` for `.waiting` drops the route:

```swift
if status.isRunning || wasRunning || status == .stopped {
    Task { await self.syncProxy() }
}
```

Extract the cleanup loop body of `remove(projectID:)` into:

```swift
/// Drops everything held for a service that no longer exists.
private func forget(_ service: Service) {
    assign(\.statuses[service.id], nil)
    assign(\.logs[service.id], nil)
    assign(\.tunnels[service.id], nil)
    assign(\.requests[service.id], nil)
    tunnelTargets.remove(for: service.id)
}
```

`apply(_:)`:

```swift
@discardableResult
func apply(_ edited: Project) async -> [Service] {
    let previous = projects.first { $0.id == edited.id }
    // Stopped before the save, for the reason `remove(projectID:)` gives:
    // once the row is gone nothing can reach the watch or the process.
    let removed = previous?.services.filter { edited.service(id: $0.id) == nil } ?? []
    for service in removed { await stop(service) }
    let moved = edited.services.filter { service in
        service.kind == .command
            && previous?.service(id: service.id)?.domain != service.domain
            && status(of: service).isRunning
    }
    // A route's watch holds the port it started with. Asked of the watcher,
    // not of `status`, which still reads `.starting` or a stale value while
    // the first probe or an event is in flight.
    var repointed: [Service] = []
    for service in edited.services
    where service.kind == .portRoute && previous?.service(id: service.id)?.portMode != service.portMode {
        if await routeWatcher?.isWatching(service.id) == true { repointed.append(service) }
    }
    replace(edited)
    removed.forEach(forget)
    for route in repointed { await restart(route) }
    await refreshDetectedIcons()
    await syncProxy()
    return moved
}
```

A route's domain change needs no restart: nothing was injected, and `syncProxy` carries the new host.

`AppState+Sharing`: first line of `share(_:)`, `shareNamed`, `shareSSH`: `guard service.kind == .command else { return }`.

- [ ] **Step 2: Run** `make lint && make test`.
- [ ] **Step 3: Manual check** with `make run` and a hand-edited `projects.json` holding one route on port 8081 (back the file up first, restore it after):
  - Start with nothing on 8081: status Waiting, no route (`https://<domain>` fails to connect or 404s, not 502).
  - `python3 -m http.server 8081 --bind 127.0.0.1`: Running within 2 s, the domain serves the listing.
  - Kill the server: Waiting within 2 s.
  - Stop: Stopped.
- [ ] **Step 4: Commit** `feat(app): start, stop and route port routes`

---

### Task 6: Show routes in the popover and dashboard

**Files:**
- Modify: `App/Localfox/Views/MenuView.swift`, `App/Localfox/Views/ServiceDetailPane.swift`, `App/Localfox/ServiceStatusDisplay.swift`, `App/Localfox/SnapshotFixture.swift`

- [ ] **Step 1: Implement**

`ServiceRow` (MenuView): the Stop and Restart branch keys on `status.isActive`, not `isRunning`. Same in the context menu. "Reveal in Finder" and "Open in Terminal" only when `service.directory != nil`. `shareItems` only when `service.kind == .command`.

Project header (MenuView): `anyRunning` becomes "any active" for the Start all / Stop all switch, so a project whose only route is Waiting can still be stopped. Keep the green dot on `isRunning`. Hide the path text and the reveal button when `project.directory == nil`.

`ServiceDetailPane`, for `service.kind == .portRoute`:
- Configuration card: a "Kind" row with the value "Port route" in place of Framework. No Command row. A Directory row only when there is a directory. Port row stays ("Fixed at 8081").
- Status card: the PID row is already conditional from Task 2.
- When `status` is `.waiting(port)`, a card titled "Waiting for the port" with:

```swift
static func explainWaiting(port: Int) -> String {
    """
    Nothing accepts connections on 127.0.0.1:\(port) yet. Localfox checks \
    every 2 seconds and routes the domain as soon as something does. A server \
    listening only on ::1 is not reachable, because the proxy dials 127.0.0.1.
    """
}
```

- No Share menu and no Output card.
- The header's Start / Stop / Restart switch (`ServiceDetailPane.swift` around line 203) keys on `status.isActive`, not `isRunning`, so a Waiting route can be stopped from the dashboard.

`SnapshotFixture`: add a standalone project `Project(name: "docker", directory: nil, services: [route])` where `route` is `Service.portRoute(name: "app", domain: LocalDomain("docker.localhost")!, port: 8081, directory: nil)!` with status `.running(pid: nil, port: 8081)`, and a second route with `LocalDomain("grafana.localhost")!` on 3300 with status `.waiting(port: 3300)`.

- [ ] **Step 2: Run** `make lint && make test && make snapshot`. Open the PNGs. Check that the waiting route reads "Waiting", the running route shows `:8081`, and the standalone project has no path and no folder button.
- [ ] **Step 3: Commit** `feat(app): show port routes in the popover and dashboard`

---

### Task 7: Route a Port sheet

**Files:**
- Create: `App/Localfox/Views/AddRouteSheet.swift`
- Modify: `App/Localfox/Views/DashboardView.swift`

- [ ] **Step 1: Implement** `AddRouteSheet`

Same frame, header, card and footer components as `AddProjectSheet` (`DetailCard`, `LabelledField`, `ActionButton`, `ErrorBanner`). Header symbol `arrow.left.arrow.right`, title "Route a port", subtitle "Give a port Localfox does not start a .localhost domain".

State and save:

```swift
@State private var name = ""
@State private var domain = ""
@State private var port = ""
@State private var directory: URL?
@State private var domainWasEdited = false

private var parsedPort: Int? { Int(port.trimmingCharacters(in: .whitespaces)) }

private var portError: String? {
    guard !port.isEmpty else { return nil }
    guard let parsedPort, Service.isRoutablePort(parsedPort) else {
        return "Use a port from 1 to 65535, other than 80 and 443"
    }
    return nil
}

private var domainError: String? {
    guard !domain.isEmpty else { return nil }
    guard let value = LocalDomain(domain) else { return "Must be a valid .localhost name" }
    if let owner = state.domainOwner(of: value, excluding: []) { return "Already used by \(owner.name)" }
    return nil
}

private var canSave: Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty
        && LocalDomain(domain) != nil && domainError == nil
        && parsedPort != nil && portError == nil
}

private func save() {
    guard let value = LocalDomain(domain), let parsedPort,
          let route = Service.portRoute(name: name.trimmingCharacters(in: .whitespaces),
                                        domain: value, port: parsedPort, directory: directory)
    else { return }
    state.add(Project(name: route.name, directory: directory, services: [route]))
    dismiss()
}
```

Domain suggestion: on `name` change, when `!domainWasEdited`, set `domain = "\(LocalDomain.slug(name)).localhost"`. Typing in the domain field sets `domainWasEdited = true`. Use an `onChange` on `domain` that compares against the suggested value, rather than a second binding.

Fields: Name, Domain, Port, and a Folder row showing `directory?.path ?? "None"` with "Choose…" and, when set, "Clear". "Choose…" uses `NSOpenPanel` the same way `AddProjectSheet.chooseDirectory()` does, without scanning. Hint under the port: "Docker, an SSH forward or a server you started yourself. Localfox routes the domain while 127.0.0.1:<port> accepts connections."

Primary button "Add Route", symbol `plus`.

`DashboardView`: replace the `plus` `IconButton` with a `Menu` of the same look, holding "Add Project…" (`isAddingProject = true`) and "Route a Port…" (`isAddingRoute = true`). Add `@State private var isAddingRoute = false` and `.sheet(isPresented: $isAddingRoute) { AddRouteSheet().environment(state) }`. If `IconButton` cannot host a `Menu` label cleanly, use `Menu { … } label: { Image(systemName: "plus") … }` with `.menuStyle(.borderlessButton)` and `.menuIndicator(.hidden)`, sized to `Theme.Metrics.headerButtonSize`. The empty-state sidebar keeps "Add Project" and gains a secondary `ActionButton(title: "Route a Port", symbol: "arrow.left.arrow.right")`.

- [ ] **Step 2: Run** `make lint && make test && make run`. Add a route on 8081 with no folder. Start it with and without a server on the port.
- [ ] **Step 3: Commit** `feat(app): add a sheet to route a port`

---

### Task 8: Add and remove routes in Edit Project

**Files:**
- Modify: `App/Localfox/Views/EditProjectSheet.swift`

- [ ] **Step 1: Implement**

`EditableService` gains `let kind: ServiceKind`, `var port: String` (from `portMode.fixedValue`, blank for a command), and `let isNew: Bool`. A memberwise-style initializer for a new route row:

```swift
static func newRoute() -> EditableService  // id UUID(), name "", domain "", kind .portRoute, port "", isNew true, framework .unknown, directory nil
```

Sheet: below the rows, `ActionButton(title: "Add Port Route", symbol: "plus") { rows.append(.newRoute()) }`.

`ServiceEditor` for a `.portRoute` row: a Port field in place of Command, with the same error copy as `AddRouteSheet`. No sharing section. A trash `IconButton` in the card header that calls an `onRemove` closure the sheet passes in, which removes the row. Command rows get no remove button. Removing services Localfox detected is out of scope.

`suggestDomains`: only rows with `kind == .command` take part, so a rename never rewrites a route's domain. Build `names` and `apexIndex` over that subset and map back to row indices.

`editedIDs`: every service of the original `project` plus every row id, so a removed route's domain can be reused by another row in the same edit. Duplicate detection across `rows` stays.

`canSave`: a `.portRoute` row also needs `Int(port).map(Service.isRoutablePort) == true`.

`save()`: build `edited.services` from `rows`, not from `project.services`, so added rows appear and removed rows disappear. Existing rows update as today, plus `portMode = .fixed(port)` for a route. New rows go through `Service.portRoute(name:domain:port:directory: project.directory)`. Keep row order.

`saveTunnelTargets` skips route rows.

- [ ] **Step 2: Run** `make lint && make test && make run`. Manual check, Review Focus item 3:
  - Add a route to an existing project, save, start it.
  - With it running, change its port, save. Status re-evaluates against the new port, and the old port no longer serves the domain.
  - Remove it while running, save. Its row is gone, and its domain no longer resolves through the proxy.
- [ ] **Step 3: Commit** `feat(app): add and remove port routes when editing a project`

---

### Task 9: Document port routes

**Files:**
- Modify: `README.md`, `.claude/CLAUDE.md`, `CHANGELOG.md`

- [ ] **Step 1: Write**

README, a short "Port routes" section. It covers what a route is, Start and Stop, the 127.0.0.1-only probe, no sharing yet, and that 1.2.0 cannot open a configuration saved by this version.

`.claude/CLAUDE.md`, a "Port routes" section with these rules:
- **A route is watched, not owned.** It has no process group, so no signal ever goes to whatever holds its port.
- **Waiting has no route.** A route to a closed port serves 502 under a domain that looks configured.
- **The probe dials `127.0.0.1` because Caddy does.** A `::1`-only server is reported as Waiting on purpose.
- **Routes are not shareable yet.** Tunnel teardown keys on the origin process group, which a route does not have.
- **Store version 2.** Bumping the version is what stops a 1.x build reading a route as an empty command. `ProjectStore` refuses to save after a failed load, so a refused file is never overwritten.

CHANGELOG, an "Unreleased" entry.

- [ ] **Step 2: Commit** `docs: describe port routes`

---

## Out of scope

- Public sharing of a route. Needs `TunnelRuntime` to stop on route status instead of `originGroup` liveness.
- Managed `ssh -L` forwards. A later step, as a command service whose command is `ssh -N -L`.
- A telemetry signal for routes. `projectAdded` and `serviceStarted` already fire.
- `localfox-run` support. The CLI does not read the store.
