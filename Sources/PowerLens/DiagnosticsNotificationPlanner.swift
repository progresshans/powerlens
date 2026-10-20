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
    /// Minimum time between repeat notifications for the same diagnostic kind.
    var debounceInterval: TimeInterval = 30 * 60

    /// Decides which diagnostics warrant a notification right now.
    ///
    /// - Only non-`info` diagnostics (caution/warning) are considered.
    /// - A kind is suppressed if it was notified within `debounceInterval`.
    /// - Entries for diagnostics that are no longer active are dropped so a
    ///   condition that clears and later recurs can alert again immediately.
    func plan(
        diagnostics: [DiagnosticItem],
        lastNotified: [DiagnosticKind: Date],
        now: Date
    ) -> (notifications: [DiagnosticNotification], lastNotified: [DiagnosticKind: Date]) {
        var updated = lastNotified
        var notifications: [DiagnosticNotification] = []

        for item in diagnostics where item.severity != .info {
            if let last = updated[item.kind], now.timeIntervalSince(last) < debounceInterval {
                continue
            }

            updated[item.kind] = now
            notifications.append(DiagnosticNotification(title: item.title, body: item.message))
        }

        let activeKinds = Set(diagnostics.map(\.kind))
        updated = updated.filter { activeKinds.contains($0.key) }

        return (notifications, updated)
    }
}
