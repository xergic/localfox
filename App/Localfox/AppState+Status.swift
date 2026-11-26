import Foundation
import LocalfoxKit

@MainActor
extension AppState {
    func proxyRoute(for service: Service) -> ProxyRoute? {
        guard case let .running(_, port, family) = status(of: service) else { return nil }
        return ProxyRoute(id: String(service.id.uuidString.prefix(8)), domain: service.domain, port: port, family: family)
    }

    /// Enable Open only after the helper has accepted this exact route.
    func url(for service: Service) -> URL? {
        guard !needsSetup, let route = proxyRoute(for: service), servedRoutes.contains(route) else { return nil }
        return service.url
    }

    /// Local HTTPS needs both a running proxy and a trusted certificate.
    var needsSetup: Bool {
        !helper.isProxyRunning || !trust.isUsable
    }
}
