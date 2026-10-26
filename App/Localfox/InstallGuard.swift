import AppKit
import Sparkle

/// Quitting runs `stopEverything()`, and Sparkle quits the app to install, so a
/// click on Install would otherwise stop every dev server without a word.
@MainActor
final class InstallGuard: NSObject, SPUUpdaterDelegate {
    /// Lets a signed release candidate be tested from an installed build:
    /// `defaults write net.kandera.Localfox UpdateFeedOverride <https URL>`.
    /// Harmless, because every update still has to carry this app's EdDSA signature.
    private static let feedOverrideKey = "UpdateFeedOverride"

    private weak var state: AppState?
    /// Sparkle waits for this forever once relaunch is postponed, so Later keeps
    /// it and installs as soon as nothing is running, instead of dropping it.
    private var pendingInstall: (() -> Void)?

    init(state: AppState) {
        self.state = state
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let override = UserDefaults.standard.string(forKey: Self.feedOverrideKey),
              override.hasPrefix("https://")
        else { return nil }
        return override
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        let running = state?.runningCount ?? 0
        guard running > 0 else { return false }
        let alert = NSAlert()
        alert.messageText = "Installing stops \(running) running service\(running == 1 ? "" : "s")."
        alert.informativeText = "Localfox stops every service it started when it quits to install the update. "
            + "Choose Later to install it once you have stopped them."
        alert.addButton(withTitle: "Install Now")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            installHandler()
        } else {
            pendingInstall = installHandler
            installWhenIdle()
        }
        return true
    }

    private func installWhenIdle() {
        guard let state, pendingInstall != nil else { return }
        guard state.runningCount > 0 else {
            let install = pendingInstall
            pendingInstall = nil
            install?()
            return
        }
        withObservationTracking {
            _ = state.runningCount
        } onChange: { [weak self] in
            Task { @MainActor in self?.installWhenIdle() }
        }
    }
}
