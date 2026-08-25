import Foundation

/// Asks whether a public address answers yet.
///
/// Deliberately not `HTTPProbe`, which refuses anything that is not loopback and
/// must keep refusing it: that guard is what stops the app being walked off the
/// machine by a dev server's redirect. This is the one place Localfox reaches a
/// remote host, and it only ever uses an address the user typed themselves.
public enum PublicReachability {
    /// One session for every probe, rather than one per call.
    ///
    /// The watch loop probes repeatedly while a share comes up, and a session
    /// torn down between calls takes its connection pool with it, so every probe
    /// would redo the TCP and TLS handshake to the user's server.
    /// `NoRedirectDelegate` is shared with `HTTPProbe` for the same reason it
    /// exists there: report the first response, never the end of a chain.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(
            configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil
        )
    }()

    /// True once something answers, whatever it answers with.
    ///
    /// Any HTTP status counts. The question is whether the forward carries a
    /// request end to end, and a 404 from the user's own server proves that just
    /// as well as a 200.
    public static func isReachable(_ url: URL, timeout: Duration = .seconds(3)) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        // Per request rather than on the configuration, so one shared session can
        // still be bounded. `timeInterval` and not `components.seconds`, which
        // floors a sub-second timeout to zero.
        request.timeoutInterval = timeout.timeInterval
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return response is HTTPURLResponse
    }
}
