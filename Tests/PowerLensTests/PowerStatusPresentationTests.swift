import Testing
@testable import PowerLens

struct PowerStatusPresentationTests {
    @Test
    func chargingSaysWhereThePowerGoes() {
        let snapshot = makeTelemetrySnapshot(
            isCharging: true,
            batteryCurrentA: 3.44,
            batteryPowerW: -46.4,
            adapterInputPowerW: 53.6,
            systemLoadW: 7.2
        )

        let status = PowerStatusPresentation(snapshot: snapshot, resolvedState: nil)

        #expect(status.tone == .charging)
        #expect(status.title == L10n.text("status.title.charging"))
        #expect(status.subtitle == L10n.tr("status.subtitle.chargingSplit", "7.2W", "46.4W"))
    }

    @Test
    func onBatteryLeadsWithTimeRemaining() {
        let snapshot = makeTelemetrySnapshot(
            powerSource: .battery,
            externalConnected: false,
            timeToEmptyMinutes: 252,
            batteryCurrentA: -0.82,
            batteryPowerW: 12.4,
            adapterInputPowerW: 0,
            systemLoadW: 12.4,
            adapterMaxPowerW: nil
        )

        let status = PowerStatusPresentation(snapshot: snapshot, resolvedState: nil)

        #expect(status.tone == .neutral)
        #expect(status.title == L10n.tr("status.title.timeRemaining", Formatters.minutes(252)))
        #expect(status.subtitle == L10n.tr("status.subtitle.macUsing", "12.4W"))
    }

    @Test
    func holdingNamesTheLevelBeingKept() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: 0,
            batteryPowerW: 0,
            adapterInputPowerW: 11.7,
            systemLoadW: 11.7
        )

        let status = PowerStatusPresentation(snapshot: snapshot, resolvedState: nil)

        #expect(status.tone == .charger)
        #expect(status.title == L10n.text("status.title.holding"))
        #expect(status.subtitle == L10n.tr("status.subtitle.holding", "80%"))
    }

    @Test
    func healthyStateShowsNoNotice() {
        let snapshot = makeTelemetrySnapshot()
        let healthy = DiagnosticItem(kind: .healthy, severity: .info, title: "t", message: "m")

        #expect(PowerNotice.current(snapshot: snapshot, resolvedState: nil, diagnostics: [healthy]) == nil)
    }
}
