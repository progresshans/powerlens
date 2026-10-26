import Foundation
import Testing
@testable import PowerLens

/// Builds every popover and Dashboard presentation from a snapshot with no
/// readings at all. Missing data must read as unknown: no reassuring claim,
/// no gauge fill, and no assumed value.
struct EmptySnapshotPresentationTests {
    private func emptySnapshot(externalConnected: Bool) -> TelemetrySnapshot {
        TelemetrySnapshot(
            timestamp: Date(timeIntervalSince1970: 1_775_000_000),
            batteryLevel: nil,
            powerSource: externalConnected ? .ac : .battery,
            isCharging: false,
            isCharged: false,
            externalConnected: externalConnected,
            timeToEmptyMinutes: nil,
            timeToFullMinutes: nil,
            designCapacityMah: nil,
            fullChargeCapacityMah: nil,
            nominalCapacityMah: nil,
            cycleCount: nil,
            designCycleCount: nil,
            batteryHealthText: nil,
            batteryHealthCondition: nil,
            batteryTemperatureC: nil,
            batteryVoltageV: nil,
            batteryCurrentA: nil,
            batteryPowerW: nil,
            batteryPowerSource: nil,
            adapterDescription: nil,
            adapterMaxPowerW: nil,
            adapterInputPowerW: nil,
            adapterVoltageV: nil,
            adapterCurrentA: nil,
            systemLoadW: nil,
            powerMeasurementSetSource: nil,
            lowPowerModeEnabled: false,
            thermalState: "",
            serialNumber: nil,
            frontmostAppName: nil,
            chargingPolicyStatus: nil
        )
    }

    /// Everything the popover and Dashboard would say about this snapshot.
    private func shownText(_ snapshot: TelemetrySnapshot) -> [String] {
        let readings = PowerFlowReadings(snapshot: snapshot)
        let status = PowerStatusPresentation(snapshot: snapshot, resolvedState: nil)
        let tiles = [
            MetricTilePresentation.battery(snapshot: snapshot, resolvedState: nil),
            MetricTilePresentation.health(snapshot: snapshot),
            MetricTilePresentation.temperature(snapshot: snapshot),
        ]
        let health = BatteryHealthPresentation(snapshot.batteryHealthAssessment)
        let charger = ChargerUsagePresentation(snapshot: snapshot, readings: readings)
        let method = ChargingMethodPresentation(policy: snapshot.chargingPolicyStatus)
        let graph = PowerFlowGraph(model: PowerFlowPresentationModel(snapshot: snapshot))

        return [status.capsuleTitle, status.title, status.subtitle]
            + tiles.flatMap { [$0.value, $0.caption] }
            + [health.title, health.capsuleTitle]
            + [charger.value, charger.caption, method.value, method.caption]
            + [DashboardInsight.temperatureTitle(snapshot: snapshot)]
            + (graph.sources + graph.destinations).map(\.value)
    }

    /// Statements that are only true when a reading backs them up.
    private var reassuringClaims: [String] {
        [
            "health.normal", "battery.title.good", "battery.capsule.good",
            "charger.usage.light", "charger.usage.half",
            "battery.charging.default", "battery.charging.defaultCaption",
            "thermal.nominal",
        ].map(L10n.text)
    }

    @Test(arguments: [true, false])
    func missingReadingsMakeNoReassuringClaims(externalConnected: Bool) {
        let shown = shownText(emptySnapshot(externalConnected: externalConnected))

        for claim in reassuringClaims {
            #expect(!shown.contains { $0.contains(claim) }, "\"\(claim)\" shown without a reading")
        }
    }

    @Test(arguments: [true, false])
    func missingReadingsDrawNoGaugeFill(externalConnected: Bool) {
        let snapshot = emptySnapshot(externalConnected: externalConnected)
        let readings = PowerFlowReadings(snapshot: snapshot)

        #expect(DashboardGauge.batteryLevel(snapshot) == nil)
        #expect(DashboardGauge.capacity(snapshot) == nil)
        #expect(DashboardGauge.cycles(snapshot) == nil)
        #expect(ChargerUsagePresentation(snapshot: snapshot, readings: readings).fraction == nil)
        #expect(ChargingMethodPresentation(policy: snapshot.chargingPolicyStatus).fraction == nil)
    }

    @Test
    func missingLevelShowsAGenericBatteryIcon() {
        #expect(BatterySymbol.name(level: nil, isCharging: false) == "minus.plus.batteryblock")
    }

    @Test
    func unknownChargerInputIsNotSpareCapacity() {
        // The rating is known but the flow cannot balance, so the input is.
        let snapshot = makeTelemetrySnapshot(
            batteryVoltageV: nil, batteryCurrentA: -1, batteryPowerW: nil,
            adapterInputPowerW: 10, systemLoadW: 15
        )
        let usage = ChargerUsagePresentation(snapshot: snapshot, readings: PowerFlowReadings(snapshot: snapshot))

        #expect(usage.caption == L10n.text("charger.usage.unknown"))
        #expect(usage.fraction == nil)
        #expect(usage.unit == "/ 97W")
    }

    @Test
    func knownChargerInputIsInterpreted() {
        let snapshot = makeTelemetrySnapshot(adapterInputPowerW: 11, systemLoadW: 11)
        let usage = ChargerUsagePresentation(snapshot: snapshot, readings: PowerFlowReadings(snapshot: snapshot))

        #expect(usage.caption == L10n.text("charger.usage.light"))
        #expect(usage.fraction.map { abs($0 - 11.0 / 97) < 0.01 } == true)
    }
}
