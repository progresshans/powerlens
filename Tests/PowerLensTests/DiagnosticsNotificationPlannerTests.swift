import Foundation
import Testing
@testable import PowerLens

struct DiagnosticsNotificationPlannerTests {
    private func item(_ title: String, severity: DiagnosticSeverity = .warning) -> DiagnosticItem {
        DiagnosticItem(severity: severity, title: title, message: "message for \(title)")
    }

    @Test
    func infoDiagnosticsAreNotNotified() {
        let planner = DiagnosticsNotificationPlanner()
        let now = Date(timeIntervalSince1970: 1_000_000)

        let result = planner.plan(
            diagnostics: [item("Power Flow Looks Healthy", severity: .info)],
            lastNotified: [:],
            now: now
        )

        #expect(result.notifications.isEmpty)
    }

    @Test
    func warningIsNotifiedThenDebounced() {
        let planner = DiagnosticsNotificationPlanner()
        let now = Date(timeIntervalSince1970: 1_000_000)

        let first = planner.plan(diagnostics: [item("Slow Charger Detected")], lastNotified: [:], now: now)
        #expect(first.notifications.count == 1)

        let second = planner.plan(
            diagnostics: [item("Slow Charger Detected")],
            lastNotified: first.lastNotified,
            now: now.addingTimeInterval(600)
        )
        #expect(second.notifications.isEmpty)
    }

    @Test
    func renotifiesAfterDebounceInterval() {
        let planner = DiagnosticsNotificationPlanner()
        let now = Date(timeIntervalSince1970: 1_000_000)

        let first = planner.plan(diagnostics: [item("Slow Charger Detected")], lastNotified: [:], now: now)
        let later = planner.plan(
            diagnostics: [item("Slow Charger Detected")],
            lastNotified: first.lastNotified,
            now: now.addingTimeInterval(31 * 60)
        )

        #expect(later.notifications.count == 1)
    }

    @Test
    func clearedDiagnosticRenotifiesOnRecurrence() {
        let planner = DiagnosticsNotificationPlanner()
        let now = Date(timeIntervalSince1970: 1_000_000)

        let first = planner.plan(diagnostics: [item("Slow Charger Detected")], lastNotified: [:], now: now)
        let cleared = planner.plan(diagnostics: [], lastNotified: first.lastNotified, now: now.addingTimeInterval(60))
        #expect(cleared.notifications.isEmpty)
        #expect(cleared.lastNotified.isEmpty)

        let recurred = planner.plan(
            diagnostics: [item("Slow Charger Detected")],
            lastNotified: cleared.lastNotified,
            now: now.addingTimeInterval(120)
        )
        #expect(recurred.notifications.count == 1)
    }
}
