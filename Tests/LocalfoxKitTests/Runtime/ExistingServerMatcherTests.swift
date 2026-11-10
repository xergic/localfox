import Foundation
import Testing
@testable import LocalfoxKit

@Suite("finding a server that already runs a project")
struct ExistingServerMatcherTests {
    private static let project = "/Users/me/app"
    private static let uid: uid_t = 501

    private static func process(
        _ pid: pid_t, parent: pid_t = 1, name: String, args: [String] = [], cwd: String?, uid: uid_t = uid
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid, parentPID: parent, uid: uid, startTime: nil,
            executablePath: "/usr/local/bin/\(name)", arguments: args.isEmpty ? [name] : args, workingDirectory: cwd
        )
    }

    private static func socket(_ pid: pid_t, _ port: Int, family: ListeningSocket.AddressFamily = .ipv4) -> ListeningSocket {
        ListeningSocket(pid: pid, port: port, host: "127.0.0.1", family: family)
    }

    private func match(
        _ processes: [ProcessSnapshot],
        _ sockets: [ListeningSocket],
        owned: Set<pid_t> = [],
        excludedPorts: Set<Int> = [],
        groups: [pid_t: pid_t] = [:]
    ) -> [ExistingServer] {
        ExistingServerMatcher.servers(
            sockets: sockets,
            tree: ProcessTree(processes: processes),
            scope: .init(directory: Self.project, ownUID: Self.uid, ownedGroups: owned, excludedPorts: excludedPorts),
            processGroup: { groups[$0] }
        )
    }

    @Test("a listener whose cwd is the folder matches")
    func cwdEqual() {
        let found = match([Self.process(10, name: "node", cwd: Self.project)], [Self.socket(10, 3000)])

        #expect(found == [ExistingServer(pid: 10, port: 3000, executableName: "node")])
    }

    @Test("a listener whose cwd is inside the folder matches")
    func cwdInside() {
        let found = match([Self.process(10, name: "node", cwd: Self.project + "/apps/web")], [Self.socket(10, 3000)])

        #expect(found.map(\.port) == [3000])
    }

    @Test("a sibling folder that only shares the prefix does not match")
    func siblingPrefix() {
        let found = match([Self.process(10, name: "node", cwd: Self.project + "-other")], [Self.socket(10, 3000)])

        #expect(found.isEmpty)
    }

    @Test("a listener with no readable cwd and no matching ancestor does not match")
    func unreadableCwd() {
        #expect(match([Self.process(10, name: "node", cwd: nil)], [Self.socket(10, 3000)]).isEmpty)
    }

    @Test("an ancestor's cwd matches when the listener's own does not")
    func ancestorMatch() {
        let found = match(
            [
                Self.process(20, name: "pnpm", args: ["pnpm", "dev"], cwd: Self.project),
                Self.process(10, parent: 20, name: "node", cwd: "/")
            ],
            [Self.socket(10, 3000)]
        )

        #expect(found.map(\.pid) == [10])
    }

    @Test("the walk stops at a shell, so a terminal opened in the folder claims nothing")
    func shellBoundary() {
        let found = match(
            [
                Self.process(30, name: "zsh", cwd: Self.project),
                Self.process(10, parent: 30, name: "node", cwd: "/")
            ],
            [Self.socket(10, 3000)]
        )

        #expect(found.isEmpty)
    }

    @Test("an ancestor beyond a shell is never reached")
    func ancestorBehindShell() {
        let found = match(
            [
                Self.process(40, name: "claude", cwd: Self.project),
                Self.process(30, parent: 40, name: "zsh", cwd: "/"),
                Self.process(10, parent: 30, name: "node", cwd: "/")
            ],
            [Self.socket(10, 3000)]
        )

        #expect(found.isEmpty)
    }

    @Test("a shell running a command is a wrapper, so the walk passes through it")
    func commandShellIsNotABoundary() {
        let found = match(
            [
                Self.process(40, name: "claude", cwd: Self.project),
                Self.process(30, parent: 40, name: "zsh", args: ["zsh", "-c", "pnpm dev"], cwd: "/"),
                Self.process(10, parent: 30, name: "node", cwd: "/")
            ],
            [Self.socket(10, 3000)]
        )

        #expect(found.map(\.pid) == [10])
    }

    @Test("a server in a group Localfox spawned is not already running")
    func ownGroupIsExcluded() {
        let processes = [
            Self.process(10, name: "node", cwd: Self.project),
            Self.process(11, name: "node", cwd: Self.project)
        ]
        let found = match(
            processes, [Self.socket(10, 3000), Self.socket(11, 3001)],
            owned: [900], groups: [10: 900, 11: 11]
        )

        #expect(found.map(\.port) == [3001])
    }

    @Test("another user's process is ignored")
    func otherUser() {
        let found = match([Self.process(10, name: "node", cwd: Self.project, uid: 0)], [Self.socket(10, 3000)])

        #expect(found.isEmpty)
    }

    @Test("ports 80, 443 and the ephemeral range are ignored")
    func portsThatCannotBeRouted() {
        let sockets = [80, 443, 49_151, 49_152, 60_000].map { Self.socket(10, $0) }

        let found = match([Self.process(10, name: "node", cwd: Self.project)], sockets)

        #expect(found.map(\.port) == [49_151])
    }

    @Test("a port another route already holds is skipped")
    func excludedPort() {
        let found = match(
            [Self.process(10, name: "node", cwd: Self.project)],
            [Self.socket(10, 3000), Self.socket(10, 3001)],
            excludedPorts: [3000]
        )

        #expect(found.map(\.port) == [3001])
    }

    @Test("both address families of one listener are one entry, lowest port first")
    func dedupeAndOrder() {
        let found = match(
            [Self.process(10, name: "node", cwd: Self.project)],
            [Self.socket(10, 5173), Self.socket(10, 3000), Self.socket(10, 3000, family: .ipv6)]
        )

        #expect(found.map(\.port) == [3000, 5173])
    }

    @Test("the lowest port wins when none answers HTTP")
    func lowestPort() {
        let servers = [3000, 9229].map { ExistingServer(pid: 10, port: $0, executableName: "node") }

        #expect(ExistingServerMatcher.preferred(from: servers, answeringHTTP: [])?.port == 3000)
    }

    @Test("a server that answers HTTP beats a lower port that does not")
    func httpBeatsLowerPort() {
        let servers = [3000, 5173].map { ExistingServer(pid: 10, port: $0, executableName: "node") }

        #expect(ExistingServerMatcher.preferred(from: servers, answeringHTTP: [5173])?.port == 5173)
        #expect(ExistingServerMatcher.preferred(from: [], answeringHTTP: [5173]) == nil)
    }
}
