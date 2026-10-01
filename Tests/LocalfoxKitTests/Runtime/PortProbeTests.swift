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
