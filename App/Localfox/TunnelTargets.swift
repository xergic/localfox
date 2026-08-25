import Foundation
import LocalfoxKit
import Observation

/// The named tunnel a service can be shared through, if the user configured one.
///
/// Deliberately not in `projects.json`. The same reasoning as
/// `SharingPreferences`: this is a fact about the user's Cloudflare account and
/// not about the project directory, so a project copied to a colleague's machine
/// must not carry it, and the store stays at version 1. The token goes further
/// still and lives in the Keychain, because it is a bearer credential.
@MainActor
@Observable
final class TunnelTargets {
    /// A configured named tunnel. The token is fetched separately and on demand,
    /// so it is never held in observable state the interface can redraw from.
    struct Named: Equatable {
        let hostname: URL
    }

    private enum Key {
        static func hostname(_ serviceID: UUID) -> String {
            "tunnel.named.hostname.\(serviceID.uuidString)"
        }

        static func ssh(_ serviceID: UUID) -> String {
            "tunnel.ssh.\(serviceID.uuidString)"
        }
    }

    private let defaults: UserDefaults
    /// Mirrors what is on disk so a view reading `named(for:)` redraws when the
    /// edit sheet saves. `UserDefaults` is not observable on its own.
    private var hostnames: [UUID: URL] = [:]
    private var sshTargets: [UUID: SSHTunnelTarget] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The configured hostname, or nil when this service has no named tunnel.
    func named(for serviceID: UUID) -> Named? {
        if let cached = hostnames[serviceID] { return Named(hostname: cached) }
        guard let stored = defaults.string(forKey: Key.hostname(serviceID)),
              let url = Self.url(from: stored)
        else { return nil }
        hostnames[serviceID] = url
        return Named(hostname: url)
    }

    /// Whether a named share can be started right now, which needs both halves.
    func isConfigured(_ serviceID: UUID) -> Bool {
        named(for: serviceID) != nil && token(for: serviceID) != nil
    }

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
        if hostnames[serviceID] != url { hostnames[serviceID] = url }
        defaults.set(url.absoluteString, forKey: Key.hostname(serviceID))
        if let token { Keychain.setSecret(token, account: serviceID.uuidString) }
    }

    func clearNamed(for serviceID: UUID) {
        hostnames[serviceID] = nil
        defaults.removeObject(forKey: Key.hostname(serviceID))
        Keychain.setSecret(nil, account: serviceID.uuidString)
    }

    // MARK: - SSH

    /// The VPS this service forwards to, or nil.
    ///
    /// Plain `UserDefaults` with no Keychain half. An ssh target names a host, a
    /// user and a path to a key; the key itself never comes near Localfox.
    func ssh(for serviceID: UUID) -> SSHTunnelTarget? {
        if let cached = sshTargets[serviceID] { return cached }
        guard let data = defaults.data(forKey: Key.ssh(serviceID)),
              let target = try? JSONDecoder().decode(SSHTunnelTarget.self, from: data)
        else { return nil }
        sshTargets[serviceID] = target
        return target
    }

    func setSSH(_ target: SSHTunnelTarget?, for serviceID: UUID) {
        guard let target, let data = try? JSONEncoder().encode(target) else {
            sshTargets[serviceID] = nil
            defaults.removeObject(forKey: Key.ssh(serviceID))
            return
        }
        if sshTargets[serviceID] != target { sshTargets[serviceID] = target }
        defaults.set(data, forKey: Key.ssh(serviceID))
    }

    /// The SSH block of the edit sheet, still as typed.
    ///
    /// Strings rather than an `SSHTunnelTarget` because a half-filled form is
    /// the normal state of one, and a model that can only hold valid values has
    /// nowhere to put "the user is still typing the port".
    struct SSHFields: Equatable {
        var host = ""
        var user = ""
        var sshPort = ""
        var remotePort = ""
        var keyPath = ""
        var publicURL = ""

        /// Everything a share needs, or nil while these fields do not describe
        /// one yet. One definition, so the validator and the save agree on what
        /// counts as configured.
        var target: SSHTunnelTarget? {
            let host = host.trimmingCharacters(in: .whitespaces)
            let user = user.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, !user.isEmpty,
                  let remote = Int(remotePort.trimmingCharacters(in: .whitespaces)),
                  (1...65_535).contains(remote)
            else { return nil }

            let trimmedSSHPort = sshPort.trimmingCharacters(in: .whitespaces)
            let port = trimmedSSHPort.isEmpty ? 22 : Int(trimmedSSHPort) ?? 0
            guard (1...65_535).contains(port) else { return nil }

            let address = publicURL.trimmingCharacters(in: .whitespaces)
            let resolved = address.isEmpty
                ? SSHTunnelTarget.defaultPublicURL(host: host, remotePort: remote)
                : URL(string: address.contains("://") ? address : "http://\(address)")
            guard let resolved, resolved.host != nil else { return nil }

            let key = keyPath.trimmingCharacters(in: .whitespaces)
            return SSHTunnelTarget(
                host: host,
                user: user,
                sshPort: port,
                remotePort: remote,
                keyPath: key.isEmpty ? nil : key,
                publicURL: resolved
            )
        }

        /// True once the user has started filling this block in.
        var isTouched: Bool {
            [host, user, remotePort].contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }

        init(_ target: SSHTunnelTarget? = nil) {
            guard let target else { return }
            host = target.host
            user = target.user
            sshPort = target.sshPort == 22 ? "" : String(target.sshPort)
            remotePort = String(target.remotePort)
            keyPath = target.keyPath ?? ""
            publicURL = target.publicURL.absoluteString
        }
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
