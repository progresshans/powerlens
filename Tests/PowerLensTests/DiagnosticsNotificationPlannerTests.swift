import Foundation
import Testing
@testable import PowerLens

struct DiagnosticsNotificationPlannerTests {
    @Test
    func changingTheTitleDoesNotRepeatAnActiveDiagnostic() {
        let planner = DiagnosticsNotificationPlanner()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let first = planner.plan(
            diagnostics: [DiagnosticItem(
                kind: .powerDeliveryShortfall,
                severity: .warning,
                title: "Power delivery shortfall",
                message: "English"
            )],
            lastNotified: [:],
            now: now
        )
        let translated = planner.plan(
            diagnostics: [DiagnosticItem(
                kind: .powerDeliveryShortfall,
                severity: .warning,
                title: "전력 공급 부족",
                message: "한국어"
            )],
            lastNotified: first.lastNotified,
            now: now.addingTimeInterval(60)
        )

        #expect(translated.notifications.isEmpty)
    }

    @Test
    func differentDiagnosticKindsDoNotShareADebounceRecord() {
        let planner = DiagnosticsNotificationPlanner()
        let result = planner.plan(
            diagnostics: [
                DiagnosticItem(
                    kind: .powerDeliveryShortfall,
                    severity: .warning,
                    title: "Warning",
                    message: "Power"
                ),
                DiagnosticItem(
                    kind: .temperatureHigh,
                    severity: .caution,
                    title: "Warning",
                    message: "Temperature"
                ),
            ],
            lastNotified: [:],
            now: Date(timeIntervalSince1970: 1_000_000)
        )

        #expect(result.notifications.map(\.body) == ["Power", "Temperature"])
    }

    private func item(
        _ title: String,
        severity: DiagnosticSeverity = .warning,
        kind: DiagnosticKind = .powerDeliveryShortfall
    ) -> DiagnosticItem {
        DiagnosticItem(kind: kind, severity: severity, title: title, message: "message for \(title)")
    }

    @Test
    func infoDiagnosticsAreNotNotified() {
        let planner = DiagnosticsNotificationPlanner()
        let now = Date(timeIntervalSince1970: 1_000_000)

        let result = planner.plan(
            diagnostics: [item("Power Flow Looks Healthy", severity: .info, kind: .healthy)],
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
        let warningTitle = L10n.text(
            "diag.powerDeliveryShortfall.title"
        )

        let result = planner.plan(
            diagnostics: [
                item(managedChargingTitle, severity: .info, kind: .managedCharging),
                item(warningTitle),
            ],
            lastNotified: [:],
            now: now
        )

        #expect(result.notifications.map(\.title) == [warningTitle])
        #expect(result.lastNotified.keys.contains(.powerDeliveryShortfall))
        #expect(!result.lastNotified.keys.contains(.managedCharging))
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
                == [.warning, .info]
        )

        #expect(
            snapshot.diagnostics.prefix(1).map(\.title)
                == [
                    L10n.text("diag.powerDeliveryShortfall.title"),
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
