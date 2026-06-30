import Foundation

/// A notification the app intends to post for a diagnostic condition.
struct DiagnosticNotification: Equatable, Sendable {
    let title: String
    let body: String
}

/// Pure decision logic for diagnostic notifications. Keeping this separate from
/// `UNUserNotificationCenter` makes the debouncing and recurrence rules unit
/// testable without touching system frameworks.
struct DiagnosticsNotificationPlanner {
    /// Minimum time between repeat notifications for the same diagnostic title.
    var debounceInterval: TimeInterval = 30 * 60

    /// Decides which diagnostics warrant a notification right now.
    ///
    /// - Only non-`info` diagnostics (caution/warning) are considered.
    /// - A title is suppressed if it was notified within `debounceInterval`.
    /// - Entries for diagnostics that are no longer active are dropped so a
    ///   condition that clears and later recurs can alert again immediately.
    func plan(
        diagnostics: [DiagnosticItem],
        lastNotified: [String: Date],
        now: Date
    ) -> (notifications: [DiagnosticNotification], lastNotified: [String: Date]) {
        var updated = lastNotified
        var notifications: [DiagnosticNotification] = []

        for item in diagnostics where item.severity != .info {
            if let last = updated[item.title], now.timeIntervalSince(last) < debounceInterval {
                continue
            }

            updated[item.title] = now
            notifications.append(DiagnosticNotification(title: item.title, body: item.message))
        }

        let activeTitles = Set(diagnostics.map(\.title))
        updated = updated.filter { activeTitles.contains($0.key) }

        return (notifications, updated)
    }
}
