import Foundation
import Observation

/// The settings Localfox keeps for itself.
///
/// `UserDefaults` rather than the project store, because none of these is a fact
/// about a project: two are properties of the user's stack, one is whether they
/// have read a warning, and none should travel with a copied project directory.
///
/// One object rather than one per area. Each setting is a `Flag`, so a new one
/// costs a line rather than a class, and the views already read them side by
/// side.
@MainActor
@Observable
final class Preferences {
    /// A `Bool` backed by `UserDefaults`.
    ///
    /// The registered default is what makes this more than a stored property:
    /// `bool(forKey:)` answers false for an absent key, so a setting that ought
    /// to default on would be off for everyone who never opens preferences.
    struct Flag {
        let key: String
        let defaultsTo: Bool
    }

    private enum Key {
        static let rewriteHost = Flag(key: "sharing.rewriteHostHeader", defaultsTo: true)
        static let warningAccepted = Flag(key: "sharing.warningAccepted", defaultsTo: false)
        static let recordsRequests = Flag(key: "proxy.recordsRequests", defaultsTo: true)
        static let sharesUsageData = Flag(key: "telemetry.sharesUsageData", defaultsTo: true)
    }

    private let defaults: UserDefaults

    /// Sends the origin `Host: localhost:<port>` instead of the public name.
    ///
    /// On by default because Vite and Next reject an unknown host outright. Off
    /// is what an app that builds absolute URLs from the header needs: Django's
    /// `ALLOWED_HOSTS`, and any OAuth callback, want the real public name.
    var rewritesHostHeader: Bool { didSet { write(rewritesHostHeader, Key.rewriteHost, oldValue) } }

    /// Whether the user has accepted the exposure warning and asked not to see
    /// it again.
    var warningAccepted: Bool { didSet { write(warningAccepted, Key.warningAccepted, oldValue) } }

    /// Writes one JSON line per request to the proxy's access log.
    var recordsRequests: Bool { didSet { write(recordsRequests, Key.recordsRequests, oldValue) } }

    /// Sends anonymous usage counts. Applying a change is `Telemetry.setEnabled`.
    var sharesUsageData: Bool { didSet { write(sharesUsageData, Key.sharesUsageData, oldValue) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for flag in [Key.rewriteHost, Key.warningAccepted, Key.recordsRequests, Key.sharesUsageData] {
            defaults.register(defaults: [flag.key: flag.defaultsTo])
        }
        rewritesHostHeader = defaults.bool(forKey: Key.rewriteHost.key)
        warningAccepted = defaults.bool(forKey: Key.warningAccepted.key)
        recordsRequests = defaults.bool(forKey: Key.recordsRequests.key)
        sharesUsageData = defaults.bool(forKey: Key.sharesUsageData.key)
    }

    private func write(_ value: Bool, _ flag: Flag, _ oldValue: Bool) {
        guard value != oldValue else { return }
        defaults.set(value, forKey: flag.key)
    }
}
