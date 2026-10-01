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
