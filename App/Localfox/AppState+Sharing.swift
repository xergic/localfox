import Foundation
import LocalfoxKit

/// The public sharing half of `AppState`.
///
/// Split off so neither file grows past the point where the state and the
/// tunnel lifecycle can be read in one sitting. `report` rather than `assign` is
/// the only thing this seam costs, and it is deliberately the narrowest write
/// that works: the write guard for the whole observable surface has no business
/// being callable on an arbitrary key path from another file.
@MainActor
extension AppState {
    // MARK: - Public sharing

    /// Opens a public tunnel to a running service.
    ///
    /// Requires a discovered port, so this is only reachable once the status is
    /// `.running`. Under Auto the port does not exist until the dev server has
    /// bound it, and a tunnel to a port nothing is listening on serves 502s
    /// under a URL the user has already sent to somebody.
    func share(_ service: Service) async {
        guard case let .running(_, port, family) = status(of: service) else { return }
        await share(service, plan: .quick(port: port, rewritesHost: preferences.rewritesHostHeader, family: family))
    }

    /// Opens the named tunnel configured for this service.
    ///
    /// Refuses an Auto service rather than starting anyway. A tunnel run from a
    /// token takes its origin from the Cloudflare dashboard, so the port is
    /// written down there; under Auto the dev server can bind a different one
    /// and the share would point at whatever last held it.
    func shareNamed(_ service: Service) async {
        let storedToken: String?
        do {
            storedToken = try tunnelTargets.token(for: service.id)
        } catch {
            report(error.localizedDescription)
            return
        }
        guard let hostname = tunnelTargets.hostname(for: service.id), let token = storedToken else {
            report(SharingWarning.namedTunnelUnconfigured(service))
            return
        }
        guard let fixed = service.portMode.fixedValue else {
            report(SharingWarning.namedTunnelNeedsFixedPort(service))
            return
        }
        guard let port = status(of: service).port else { return }
        guard port == fixed else {
            report("\(service.name) is listening on port \(port). Restart it on the configured port \(fixed) before sharing.")
            return
        }
        await share(service, plan: .named(token: token, hostname: hostname))
    }

    /// Opens the SSH reverse tunnel configured for this service.
    ///
    /// Unlike a named tunnel this works under Auto, because the forward is built
    /// from the port Localfox just discovered rather than from anything written
    /// down elsewhere.
    func shareSSH(_ service: Service) async {
        guard let target = tunnelTargets.ssh(for: service.id) else {
            report(SharingWarning.sshTunnelUnconfigured(service))
            return
        }
        guard case let .running(_, port, family) = status(of: service) else { return }
        await share(service, plan: .ssh(target: target, port: port, family: family))
    }

    private func share(_ service: Service, plan: TunnelPlan) async {
        // Tunnel teardown keys on the origin process group, which a route does not have.
        guard service.kind == .command else { return }
        guard let tunnelRuntime, case let .running(pid?, _, _) = status(of: service) else { return }
        Telemetry.send(.shareStarted(.init(plan)))
        await tunnelRuntime.start(
            serviceID: service.id,
            plan: plan,
            // `ServiceRuntime` spawns with SETSID, so the pid is the group.
            originGroup: pid
        )
    }

    func unshare(_ service: Service) async {
        await tunnelRuntime?.stop(service.id)
    }

    func tunnel(of service: Service) -> TunnelStatus {
        tunnels[service.id] ?? .off
    }

    func publicURL(for service: Service) -> URL? {
        tunnel(of: service).url
    }
}
