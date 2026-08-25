import Foundation

/// Asks whether a public address answers yet.
///
/// Deliberately not `HTTPProbe`, which refuses anything that is not loopback and
/// must keep refusing it: that guard is what stops the app being walked off the
/// machine by a dev server's redirect. This is the one place Localfox reaches a
/// remote host, it only ever uses an address the user typed themselves, and it
/// follows no redirects.
public enum PublicReachability {
    /// True once something answers, whatever it answers with.
    ///
    /// Any HTTP status counts. The question is whether the forward carries a
    /// request end to end, and a 404 from the user's own server proves that just
    /// as well as a 200.
    public static func isReachable(_ url: URL, timeout: Duration = .seconds(3)) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Double(timeout.components.seconds)
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return response is HTTPURLResponse
    }
}
