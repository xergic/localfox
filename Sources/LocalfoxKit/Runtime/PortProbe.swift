import Darwin

/// A bare loopback TCP connect keeps port-route polling out of the server's HTTP logs.
public enum PortProbe {
    public static func accepts(
        port: Int, family: ListeningSocket.AddressFamily = .ipv4, timeout: Duration = .milliseconds(300)
    ) -> Bool {
        guard ProxyRoute.isValidPort(port) else { return false }
        let fd = socket(family == .ipv4 ? AF_INET : AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let result: Int32
        switch family {
        case .ipv4:
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
            result = connect(fd, to: &address)
        case .ipv6:
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = UInt16(port).bigEndian
            address.sin6_addr = in6addr_loopback
            result = connect(fd, to: &address)
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

    private static func connect<Address>(_ fd: Int32, to address: inout Address) -> Int32 {
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<Address>.size))
            }
        }
    }
}
