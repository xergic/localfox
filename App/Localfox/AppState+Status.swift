import Foundation
import LocalfoxKit

@MainActor
extension AppState {
    /// The URL to open, which only exists once the proxy is actually serving.
    func url(for service: Service) -> URL? {
        guard helper.canServe else { return nil }
        return service.url
    }

    /// Localfox has no unprivileged fallback, so this gates the whole interface
    /// rather than degrading it.
    var needsSetup: Bool {
        !helper.canServe || !trust.isUsable
    }
}
