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

        requestAuthorizationIfNeeded()

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
