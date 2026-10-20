import Foundation
import Security

/// The certificate Caddy is actually serving for a host.
///
/// Evaluating the root on its own with a basic X509 policy passes the moment the
/// root is in a keychain. It says nothing about the SSL policy, and nothing about
/// whether the leaf carries the host in its SAN, so the app could report the CA as
/// trusted while the browser refused the chain. Fetching the leaf is the only
/// check that asks the same question a client asks.
enum ProxyLeafFetcher {
    /// The chain as served, leaf first, then Caddy's intermediate. The leaf alone
    /// is not enough: it is signed by the intermediate, not the root, so an
    /// evaluation without it can never reach the trusted root and reported an
    /// untrusted authority whenever a service was running.
    ///
    /// Empty whenever the proxy is not serving that host yet, which is the
    /// normal case before any service has started. The caller falls back to the
    /// root-only evaluation.
    static func chain(for host: String) async -> [SecCertificate] {
        guard let url = URL(string: "https://\(host)/") else { return [] }
        let capture = LeafCapture()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        let session = URLSession(configuration: configuration, delegate: capture, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        // The handshake is the whole point, so the request is expected to fail:
        // the delegate cancels the challenge once it has the chain, which avoids
        // waking the dev server behind the proxy just to read a certificate.
        _ = try? await session.data(for: request)
        return capture.chain
    }
}

/// `URLSession` calls its delegate on its own queue, so the captured value is
/// lock-guarded rather than actor-isolated.
private final class LeafCapture: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [SecCertificate] = []

    var chain: [SecCertificate] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              !chain.isEmpty
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        lock.lock()
        captured = chain
        lock.unlock()
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
