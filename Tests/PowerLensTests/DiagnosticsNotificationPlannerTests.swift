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
    func managedChargingInfoIsNotNotifiedAlongsideAWarning() {
        let planner = DiagnosticsNotificationPlanner()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let managedChargingTitle = L10n.tr("status.manualLimit.active", "87%")
        let warningTitle = L10n.text("diag.slowCharger.title")

        let result = planner.plan(
            diagnostics: [
                item(managedChargingTitle, severity: .info),
                item(warningTitle),
            ],
            lastNotified: [:],
            now: now
        )

        #expect(result.notifications.map(\.title) == [warningTitle])
        #expect(result.lastNotified.keys.contains(warningTitle))
        #expect(!result.lastNotified.keys.contains(managedChargingTitle))
    }

    @Test
    func managedChargingInfoDoesNotDisplacePowerWarnings() {
        let snapshot = makeTelemetrySnapshot(
            batteryLevel: 70,
            batteryCurrentA: -0.5,
            batteryPowerW: 6,
            adapterInputPowerW: 20,
            systemLoadW: 28,
            adapterMaxPowerW: 100,
            chargingPolicyStatus: .manualLimit(targetPercent: 80)
        )

        #expect(
            snapshot.diagnostics.map(\.severity)
                == [.warning, .caution, .info]
        )

        let stable = TelemetrySnapshot.stableDiagnostics(
            for: [snapshot, snapshot, snapshot]
        )

        #expect(stable.map(\.severity) == [.warning, .caution, .info])
        #expect(
            stable.prefix(2).map(\.title)
                == [
                    L10n.text("diag.slowCharger.title"),
                    L10n.text("diag.negotiatedLow.title"),
                ]
        )
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
