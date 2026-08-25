import Foundation
import Testing
@testable import LocalfoxKit

@Suite("SSHTunnelCommand")
struct SSHTunnelCommandTests {
    private func target(
        sshPort: Int = 22,
        keyPath: String? = nil
    ) -> SSHTunnelTarget {
        SSHTunnelTarget(
            host: "vps.example.com",
            user: "deploy",
            sshPort: sshPort,
            remotePort: 8080,
            keyPath: keyPath,
            publicURL: URL(string: "http://vps.example.com:8080")!
        )
    }

    private func request(sshPort: Int = 22, keyPath: String? = nil) -> SpawnRequest {
        SSHTunnelCommand.request(
            target: target(sshPort: sshPort, keyPath: keyPath), localPort: 5173
        )
    }

    /// `localhost` resolves to ::1 first, and a dev server bound to IPv4 only
    /// refuses that. Same rule as the cloudflared origin.
    @Test("the forward lands on the loopback address, never the name")
    func forwardsToLoopback() {
        #expect(request().arguments.contains("8080:127.0.0.1:5173"))
        #expect(!request().arguments.contains { $0.contains("localhost") })
    }

    /// LocalDomain uses StrictHostKeyChecking=accept-new here, which trusts
    /// whatever key answers first. Batch mode fails instead, and the failure
    /// says what to do about it.
    @Test("an unknown host key fails rather than being accepted")
    func refusesToTrustAnUnknownKey() {
        let arguments = request().arguments
        #expect(arguments.contains("BatchMode=yes"))
        #expect(!arguments.contains { $0.contains("StrictHostKeyChecking") })
    }

    /// Without this ssh stays up after the forward is refused, and a dead share
    /// reports itself as live.
    @Test("a refused forward exits instead of lingering")
    func exitsOnForwardFailure() {
        #expect(request().arguments.contains("ExitOnForwardFailure=yes"))
    }

    @Test("no remote command and no tty")
    func runsNothingRemotely() {
        let arguments = request().arguments
        #expect(arguments.contains("-N"))
        #expect(arguments.contains("-T"))
        #expect(arguments.last == "deploy@vps.example.com")
    }

    @Test("the identity file and a non-default port appear only when set")
    func passesOptionalsOnlyWhenSet() throws {
        let plain = request().arguments
        #expect(!plain.contains("-i"))
        #expect(!plain.contains("-p"))

        let full = request(sshPort: 2222, keyPath: "/Users/ondra/.ssh/vps").arguments
        let key = try #require(full.firstIndex(of: "-i"))
        #expect(full[full.index(after: key)] == "/Users/ondra/.ssh/vps")
        let port = try #require(full.firstIndex(of: "-p"))
        #expect(full[full.index(after: port)] == "2222")
    }

    /// ssh reads known_hosts, the agent socket and ~/.ssh/config from HOME.
    @Test("the environment carries HOME so ssh can find its own configuration")
    func keepsHome() {
        #expect(request().environment["HOME"]?.isEmpty == false)
    }

    @Test("a host key failure says how to fix it")
    func explainsAHostKeyFailure() throws {
        let log = "Host key verification failed."
        let failure = try #require(SSHTunnelCommand.failure(in: log))
        #expect(failure.contains("Host key verification failed"))
        #expect(failure.contains("Connect to this host once from Terminal"))
    }

    @Test("a taken remote port names the likely cause")
    func explainsABoundRemotePort() throws {
        let log = "Warning: remote port forwarding failed for listen port 8080"
        let failure = try #require(SSHTunnelCommand.failure(in: log))
        #expect(failure.contains("already holds that port"))
    }

    @Test("a healthy start reports nothing, because ssh -N says nothing")
    func staysSilentOnSuccess() {
        #expect(SSHTunnelCommand.failure(in: "") == nil)
        #expect(SSHTunnelCommand.failure(in: "debug1: Authentication succeeded") == nil)
    }

    /// The address the user is handed. Plain HTTP unless they say otherwise,
    /// because a bare forward carries no TLS.
    @Test("the public address defaults to the host and the remote port")
    func buildsADefaultAddress() throws {
        let url = try #require(
            SSHTunnelTarget.defaultPublicURL(host: "vps.example.com", remotePort: 8080)
        )
        #expect(url.absoluteString == "http://vps.example.com:8080")
    }
}
