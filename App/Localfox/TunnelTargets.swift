import Foundation
import LocalfoxKit
import Observation

/// The named tunnel a service can be shared through, if the user configured one.
///
/// Deliberately not in `projects.json`. The same reasoning as
/// `Preferences`: this is a fact about the user's Cloudflare account and
/// not about the project directory, so a project copied to a colleague's machine
/// must not carry it, and the store stays at version 1. The token goes further
/// still and lives in the Keychain, because it is a bearer credential.
@MainActor
@Observable
final class TunnelTargets {
    private enum Key {
        static func hostname(_ serviceID: UUID) -> String {
            "tunnel.named.hostname.\(serviceID.uuidString)"
        }

        static func ssh(_ serviceID: UUID) -> String {
            "tunnel.ssh.\(serviceID.uuidString)"
        }
    }

    private let defaults: UserDefaults
    /// Mirrors what is on disk so a view reading `hostname(for:)` redraws when
    /// the edit sheet saves. `UserDefaults` is not observable on its own.
    ///
    /// Loaded up front rather than on a miss. Filling a cache from inside `body`
    /// writes to observable state during the read that registered the
    /// dependency, which costs an extra render pass every time a new service is
    /// selected.
    private var hostnames: [UUID: URL] = [:]
    private var sshTargets: [UUID: SSHTunnelTarget] = [:]
    /// Which services have a token, which is a fact rather than the secret.
    ///
    /// `isConfigured` is read from a view body, and the detail pane redraws on
    /// every chunk of dev-server output. Asking the Keychain there is an XPC
    /// round trip to `securityd` per redraw, dozens per second during a Vite
    /// rebuild, and it blocks for as long as the keychain is contended.
    private var tokenHolders: Set<UUID> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Reads every stored target once, so the accessors are pure reads.
    ///
    /// Takes the services rather than scanning `UserDefaults`, because the keys
    /// are per service id and nothing else knows the full set.
    func load(serviceIDs: some Sequence<UUID>) {
        var hostnames: [UUID: URL] = [:]
        var sshTargets: [UUID: SSHTunnelTarget] = [:]
        var tokenHolders: Set<UUID> = []
        for id in serviceIDs {
            if let stored = defaults.string(forKey: Key.hostname(id)),
               let url = Self.url(from: stored) {
                hostnames[id] = url
            }
            if let data = defaults.data(forKey: Key.ssh(id)),
               let target = try? JSONDecoder().decode(SSHTunnelTarget.self, from: data) {
                sshTargets[id] = target
            }
            if Keychain.secret(account: id.uuidString) != nil { tokenHolders.insert(id) }
        }
        assign(\.hostnames, hostnames)
        assign(\.sshTargets, sshTargets)
        assign(\.tokenHolders, tokenHolders)
    }

    /// The configured hostname, or nil when this service has no named tunnel.
    func hostname(for serviceID: UUID) -> URL? {
        hostnames[serviceID]
    }

    /// Whether a named share can be started right now, which needs both halves.
    func isConfigured(_ serviceID: UUID) -> Bool {
        hostnames[serviceID] != nil && tokenHolders.contains(serviceID)
    }

    /// The secret itself, read on the share path only.
    func token(for serviceID: UUID) -> String? {
        Keychain.secret(account: serviceID.uuidString)
    }

    /// Saves both halves, or clears both when the hostname is blank.
    ///
    /// A token with no hostname would be a credential kept for a share that can
    /// never be started, so the two are written and cleared together.
    ///
    /// - Parameter token: nil leaves the stored token alone, which is what an
    ///   edit sheet showing a masked placeholder needs. An empty string clears it.
    func setNamed(hostname: String, token: String?, for serviceID: UUID) {
        guard let url = Self.url(from: hostname) else {
            clearNamed(for: serviceID)
            return
        }
        assign(\.hostnames[serviceID], url)
        defaults.set(url.absoluteString, forKey: Key.hostname(serviceID))
        guard let token else { return }
        Keychain.setSecret(token, account: serviceID.uuidString)
        assign(\.tokenHolders, tokenHolders.union([serviceID]))
    }

    func clearNamed(for serviceID: UUID) {
        assign(\.hostnames[serviceID], nil)
        assign(\.tokenHolders, tokenHolders.subtracting([serviceID]))
        defaults.removeObject(forKey: Key.hostname(serviceID))
        Keychain.setSecret(nil, account: serviceID.uuidString)
    }

    /// Forgets everything stored for a service.
    ///
    /// One call, so removing a project cannot clear one half and leave the
    /// other. A per-service key whose service no longer exists is unreachable
    /// garbage: no new service is ever given that id.
    func remove(for serviceID: UUID) {
        clearNamed(for: serviceID)
        setSSH(nil, for: serviceID)
    }

    // MARK: - SSH

    /// The VPS this service forwards to, or nil.
    ///
    /// Plain `UserDefaults` with no Keychain half. An ssh target names a host, a
    /// user and a path to a key; the key itself never comes near Localfox.
    func ssh(for serviceID: UUID) -> SSHTunnelTarget? {
        sshTargets[serviceID]
    }

    func setSSH(_ target: SSHTunnelTarget?, for serviceID: UUID) {
        guard let target, let data = try? JSONEncoder().encode(target) else {
            assign(\.sshTargets[serviceID], nil)
            defaults.removeObject(forKey: Key.ssh(serviceID))
            return
        }
        assign(\.sshTargets[serviceID], target)
        defaults.set(data, forKey: Key.ssh(serviceID))
    }

    /// Writes only when the value moved, matching `AppState.assign`. An equal
    /// write still notifies under `@Observable`, and these are read from a view
    /// body that redraws on a timer.
    private func assign<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<TunnelTargets, Value>,
        _ value: Value
    ) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }

    /// Accepts a bare hostname as well as a URL, because the Cloudflare
    /// dashboard shows a public hostname as `share.example.com` and that is what
    /// a user pastes.
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              url.scheme == "https",
              let host = url.host,
              host.contains("."),
              !host.hasSuffix(".localhost")
        else { return nil }
        return url
    }
}
