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

    private var pending: Set<UUID> = []
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
            guard hostnames[id] != nil else { continue }
            do {
                if try Keychain.containsSecret(account: id.uuidString) { tokenHolders.insert(id) }
            } catch {
                // A locked keychain is temporary. Keep the saved target reachable so Share can explain the error.
                tokenHolders.insert(id)
            }
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
    func token(for serviceID: UUID) throws -> String? {
        guard !pending.contains(serviceID) else { return nil }
        return try Keychain.secret(account: serviceID.uuidString)
    }

    struct Change {
        let id: UUID
        let hostname: URL?
        /// nil preserves the stored token, and a blank value removes it.
        let token: String?
        let ssh: SSHTunnelTarget?
    }

    /// Preferences are published only after the project is safely written. If a later
    /// credential or the project write fails, restore every earlier credential.
    func saving(
        _ changes: [Change], removing removed: [UUID] = [], project save: @MainActor () async throws -> Void
    ) async throws -> String? {
        let ids = Set(changes.map(\.id)).union(removed)
        guard pending.isDisjoint(with: ids) else { throw StoreError.projectChanged }
        pending.formUnion(ids)
        defer { pending.subtract(ids) }
        var originals: [(account: String, value: String?)] = []
        do {
            for change in changes {
                guard let token = change.token else { continue }
                let account = change.id.uuidString
                let original = try Keychain.secret(account: account)
                guard Keychain.setSecret(token, account: account) else { throw Keychain.AccessError() }
                originals.append((account, original))
            }
            try await save()
        } catch {
            var restored = true
            for original in originals.reversed() where !Keychain.setSecret(original.value, account: original.account) {
                restored = false
            }
            guard restored else { throw Keychain.AccessError() }
            throw error
        }
        for change in changes {
            assign(\.hostnames[change.id], change.hostname)
            defaults.set(change.hostname?.absoluteString, forKey: Key.hostname(change.id))
            if let token = change.token {
                if token.isEmpty { tokenHolders.remove(change.id) } else { tokenHolders.insert(change.id) }
            }
            setSSH(change.ssh, for: change.id)
        }
        let remaining = removed.filter { !removeStoredTarget(for: $0) }
        guard !remaining.isEmpty else { return nil }
        let accounts = remaining.map(\.uuidString).joined(separator: ", ")
        return """
        Localfox removed the service configuration. To finish removing its tunnel credentials, unlock your keychain and \
        use Keychain Access to delete the net.kandera.Localfox.tunnel entries for these accounts: \(accounts).
        """
    }

    /// A removed service cannot be retried in the editor. Drop its preferences after the project
    /// commit and attempt to delete the obsolete credential without reading or unlocking it.
    private func removeStoredTarget(for id: UUID) -> Bool {
        let hasNamed = defaults.string(forKey: Key.hostname(id)) != nil || tokenHolders.contains(id)
        defaults.removeObject(forKey: Key.hostname(id))
        assign(\.hostnames[id], nil)
        tokenHolders.remove(id)
        setSSH(nil, for: id)
        return !hasNamed || Keychain.deleteSecret(account: id.uuidString, allowsInteraction: false)
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
    nonisolated static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let parts = URLComponents(string: candidate),
              parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty || parts.path == "/", parts.query == nil, parts.fragment == nil,
              let host = parts.host?.lowercased(), host.contains("."),
              !host.hasSuffix(".localhost"), LocalDomain("\(host).localhost") != nil
        else { return nil }
        return URL(string: "https://\(host)")
    }
}
