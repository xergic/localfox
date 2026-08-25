import Foundation
import Observation

/// Settings that change what the proxy itself does.
///
/// Separate from `SharingPreferences` because these are not about sharing, and
/// separate from the project store for the reason written there: neither is a
/// fact about a project.
@MainActor
@Observable
final class ProxyPreferences {
    private enum Key {
        static let recordsRequests = "proxy.recordsRequests"
    }

    private let defaults: UserDefaults

    /// Writes one JSON line per request to the proxy's access log.
    ///
    /// Defaults to on, through `register(defaults:)` for the same reason the
    /// host rewrite does: `bool(forKey:)` answers false for an absent key, so a
    /// plain read would turn this off for everyone who never opens preferences.
    var recordsRequests: Bool {
        didSet {
            guard recordsRequests != oldValue else { return }
            defaults.set(recordsRequests, forKey: Key.recordsRequests)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.recordsRequests: true])
        recordsRequests = defaults.bool(forKey: Key.recordsRequests)
    }
}
