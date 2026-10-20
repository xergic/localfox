import AppKit
import LocalfoxKit
import UserNotifications

/// Posts a banner when a service Localfox started stops on its own.
///
/// Localfox owns these processes, so unlike Portfox it needs no watch list: a
/// stop the user asked for goes through `.stopping` and ends `.stopped`, which
/// makes every `.failed` a crash or a start that never came up.
@MainActor
final class CrashNotifier {
    /// Runs when the user presses Restart on a banner. Set by `AppState`, which
    /// owns the runtime.
    var onRestart: ((UUID) -> Void)?

    private var delegate: Delegate?
    private var hasAskedForPermission = false

    private static let category = "crash"
    private static let restartAction = "restart"
    fileprivate nonisolated static let serviceKey = "serviceID"

    /// Called once the app has launched, and never in a snapshot or verification
    /// run, because `UNUserNotificationCenter` wants a real running application.
    func activate() {
        let delegate = Delegate { [weak self] action, serviceID in
            Task { @MainActor in
                guard action == Self.restartAction, let serviceID else { return }
                self?.onRestart?(serviceID)
            }
        }
        self.delegate = delegate
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        let restart = UNNotificationAction(identifier: Self.restartAction, title: "Restart")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [restart], intentIdentifiers: [])
        ])
    }

    /// Asked the first time a service comes up, which is the moment a crash
    /// banner starts to mean something, rather than at launch.
    func askForPermissionOnce() {
        guard delegate != nil, !hasAskedForPermission else { return }
        hasAskedForPermission = true
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) }
    }

    func post(_ failure: ServiceStatus.Failure, of service: Service) {
        guard delegate != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(service.name) stopped"
        content.body = "\(service.domain.value). \(ServiceDetailPane.explain(failure.reason))"
        content.categoryIdentifier = Self.category
        content.userInfo = [Self.serviceKey: service.id.uuidString]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    /// `UNUserNotificationCenterDelegate` carries no main-actor annotation, so the
    /// callbacks are `nonisolated` and hop, as Portfox's notifier does.
    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        private let onResponse: @Sendable (_ action: String, _ serviceID: UUID?) -> Void

        init(onResponse: @escaping @Sendable (_ action: String, _ serviceID: UUID?) -> Void) {
            self.onResponse = onResponse
        }

        /// Without this, macOS suppresses the banner whenever Localfox is
        /// frontmost, which is precisely when the dashboard is open.
        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .list]
        }

        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse
        ) async {
            let raw = response.notification.request.content.userInfo[CrashNotifier.serviceKey] as? String
            onResponse(response.actionIdentifier, raw.flatMap(UUID.init(uuidString:)))
        }
    }
}

@MainActor
extension AppState {
    func noteStatusChange(_ status: ServiceStatus, of serviceID: UUID) {
        guard preferences.notifiesCrashes else { return }
        if status.isRunning { crashNotifier.askForPermissionOnce() }
        guard case let .failed(failure) = status,
              let service = projects.lazy.flatMap(\.services).first(where: { $0.id == serviceID }) else { return }
        crashNotifier.post(failure, of: service)
    }
}
