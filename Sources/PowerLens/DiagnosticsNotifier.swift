import Foundation
import UserNotifications

/// Thin bridge between the pure `DiagnosticsNotificationPlanner` and the system
/// notification center. Notifications are opt-in and only touch
/// `UNUserNotificationCenter` when the user has enabled them.
@MainActor
final class DiagnosticsNotifier {
    private let planner = DiagnosticsNotificationPlanner()
    private var lastNotified: [String: Date] = [:]
    private var didRequestAuthorization = false

    func process(diagnostics: [DiagnosticItem]) {
        guard NotificationPreference.enabled else {
            return
        }

        // Resolve authorization first so the debounce record is only written when
        // a notification can actually be delivered. Otherwise the first alert
        // would be suppressed for the debounce window while the permission prompt
        // is still pending.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor [weak self] in
                self?.handle(diagnostics: diagnostics, authorizationStatus: status)
            }
        }
    }

    private func handle(diagnostics: [DiagnosticItem], authorizationStatus: UNAuthorizationStatus) {
        switch authorizationStatus {
        case .notDetermined:
            // Ask once; a later refresh will deliver alerts after the user responds.
            requestAuthorizationIfNeeded()
            return
        case .authorized, .provisional, .ephemeral:
            break
        case .denied:
            return
        @unknown default:
            return
        }

        let result = planner.plan(diagnostics: diagnostics, lastNotified: lastNotified, now: Date())
        lastNotified = result.lastNotified

        guard !result.notifications.isEmpty else {
            return
        }

        let center = UNUserNotificationCenter.current()
        for notification in result.notifications {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
    }

    private func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else {
            return
        }

        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }
}
