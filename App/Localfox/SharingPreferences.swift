import Foundation
import Observation

/// The two settings that govern public sharing.
///
/// `UserDefaults` rather than the project store, because neither is a fact
/// about a project: one is a property of the user's stack and the other is
/// whether they have read a warning.
@MainActor
@Observable
final class SharingPreferences {
    private enum Key {
        static let rewriteHost = "sharing.rewriteHostHeader"
        static let warningAccepted = "sharing.warningAccepted"
    }

    private let defaults: UserDefaults

    /// Sends the origin `Host: localhost:<port>` instead of the public name.
    ///
    /// Defaults to on, which is why the read is inverted through a separate
    /// "set" key: `bool(forKey:)` returns false for an absent key, so a plain
    /// read would default this off and break Vite for everyone who never opens
    /// preferences.
    var rewritesHostHeader: Bool {
        didSet {
            guard rewritesHostHeader != oldValue else { return }
            defaults.set(rewritesHostHeader, forKey: Key.rewriteHost)
        }
    }

    /// Whether the user has accepted the exposure warning and asked not to see
    /// it again.
    var warningAccepted: Bool {
        didSet {
            guard warningAccepted != oldValue else { return }
            defaults.set(warningAccepted, forKey: Key.warningAccepted)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.rewriteHost: true])
        rewritesHostHeader = defaults.bool(forKey: Key.rewriteHost)
        warningAccepted = defaults.bool(forKey: Key.warningAccepted)
    }
}
