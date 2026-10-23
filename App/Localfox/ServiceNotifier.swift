import AppKit
import LocalfoxKit
import UserNotifications

/// Posts a banner when a service Localfox started stops on its own, and when
/// one the user started comes up while they are looking elsewhere.
///
/// Localfox owns these processes, so unlike Portfox it needs no watch list: a
/// stop the user asked for goes through `.stopping` and ends `.stopped`, which
/// makes every `.failed` a crash or a start that never came up.
@MainActor
final class ServiceNotifier {
    /// Runs when the user presses Restart on a banner. Set by `AppState`, which
    /// owns the runtime.
    var onRestart: ((UUID) -> Void)?

    private var delegate: Delegate?
    private var hasAskedForPermission = false

    private static let category = "crash"
    private static let restartAction = "restart"
    fileprivate nonisolated static let serviceKey = "serviceID"
    fileprivate nonisolated static let urlKey = "url"

    /// Called once the app has launched, and never in a snapshot or verification
    /// run, because `UNUserNotificationCenter` wants a real running application.
    func activate() {
        let delegate = Delegate { [weak self] action, serviceID, url in
            Task { @MainActor in
                if action == Self.restartAction, let serviceID {
                    self?.onRestart?(serviceID)
                } else if action == UNNotificationDefaultActionIdentifier, let url {
                    NSWorkspace.shared.open(url)
                }
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

    /// Clicking it opens the domain, which is what the user started it to do.
    func postReady(_ service: Service) {
        guard delegate != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(service.name) is ready"
        content.body = service.domain.value
        if let url = URL(string: "https://\(service.domain.value)") {
            content.userInfo = [Self.urlKey: url.absoluteString]
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    /// `UNUserNotificationCenterDelegate` carries no main-actor annotation, so the
    /// callbacks are `nonisolated` and hop, as Portfox's notifier does.
    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        private let onResponse: @Sendable (_ action: String, _ serviceID: UUID?, _ url: URL?) -> Void

        init(onResponse: @escaping @Sendable (_ action: String, _ serviceID: UUID?, _ url: URL?) -> Void) {
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
            let info = response.notification.request.content.userInfo
            let serviceID = (info[ServiceNotifier.serviceKey] as? String).flatMap(UUID.init(uuidString:))
            let url = (info[ServiceNotifier.urlKey] as? String).flatMap(URL.init(string:))
            onResponse(response.actionIdentifier, serviceID, url)
        }
    }
}

@MainActor
extension AppState {
    /// Ready only after `.starting`, which is a start the user asked for. A port
    /// route coming back on its own goes `.waiting` to `.running` and stays quiet.
    /// Only while unseen: with the popover or a focused window in front of them,
    /// the row turning green is the news.
    func noteStatusChange(_ status: ServiceStatus, from previous: ServiceStatus?, of serviceID: UUID) {
        guard preferences.notifiesCrashes else { return }
        if status.isRunning { notifier.askForPermissionOnce() }
        switch status {
        case let .failed(failure):
            guard let service = project(owning: serviceID)?.service(id: serviceID) else { return }
            notifier.post(failure, of: service)
        case .running where previous == .starting && !isMenuPresented && !NSApp.isActive:
            guard let service = project(owning: serviceID)?.service(id: serviceID) else { return }
            notifier.postReady(service)
        default:
            break
        }
    }
}
