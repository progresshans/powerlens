import Testing
@testable import PowerLens

struct PowerStateTests {
    @Test
    func batteryPowerDirectionTreatsPositiveAsDischargingAndNegativeAsCharging() {
        let discharging = makeTelemetrySnapshot(
            powerSource: .battery,
            externalConnected: false,
            batteryCurrentA: -0.82,
            batteryPowerW: 9.1,
            adapterInputPowerW: 0,
            systemLoadW: 9.1
        )
        let charging = makeTelemetrySnapshot(
            isCharging: false,
            batteryCurrentA: 3.44,
            batteryPowerW: -46.4,
            adapterInputPowerW: 53.6,
            systemLoadW: 7.2
        )

        #expect(discharging.batteryChargeInflowW == 0)
        #expect(!discharging.isBatteryChargingForDisplay)
        #expect(charging.batteryChargeInflowW == 46.4)
        #expect(charging.isBatteryChargingForDisplay)
    }

    @Test
    func externalPowerStateUsesBatteryChargeInflowWhenChargingFlagIsMissing() {
        let snapshot = makeTelemetrySnapshot(
            isCharging: false,
            batteryCurrentA: 3.44,
            batteryPowerW: -46.4,
            adapterInputPowerW: 53.6,
            systemLoadW: 7.2
        )

        #expect(snapshot.externalPowerState == .charging)
        #expect(snapshot.statusHeadline == L10n.text("status.chargingFromExternalPower"))
    }

    @Test
    func stableExternalPowerStateUsesBatteryChargeInflowWhenChargingFlagIsMissing() {
        let snapshot = makeTelemetrySnapshot(
            isCharging: false,
            batteryCurrentA: 3.44,
            batteryPowerW: -46.4,
            adapterInputPowerW: 53.6,
            systemLoadW: 7.2
        )

        let state = TelemetrySnapshot.stableExternalPowerState(
            for: [snapshot, snapshot, snapshot],
            requiredConsecutiveSamples: 3
        )

        #expect(state == .charging)
    }

    @Test
    func negotiatedLowConditionTreatsPositiveBatteryPowerAsBatteryAssist() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: nil,
            batteryPowerW: 3.0,
            adapterInputPowerW: 20,
            systemLoadW: 21,
            adapterMaxPowerW: 97
        )

        #expect(snapshot.hasNegotiatedLowCondition)
    }

    @Test
    func negotiatedLowConditionDoesNotTreatChargingPowerAsBatteryAssist() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: nil,
            batteryPowerW: -3.0,
            adapterInputPowerW: 20,
            systemLoadW: 21,
            adapterMaxPowerW: 97
        )

        #expect(!snapshot.hasNegotiatedLowCondition)
    }

    @Test
    func highBatteryAssistIsNotTreatedAsHoldingBatteryLevel() {
        let snapshot = makeTelemetrySnapshot(
            batteryLevel: 100,
            isCharged: true,
            batteryCurrentA: -0.8,
            batteryPowerW: 12,
            adapterInputPowerW: 20,
            systemLoadW: 32,
            adapterMaxPowerW: 97
        )

        #expect(!snapshot.isHoldingBatteryLevelCandidate)
        #expect(snapshot.externalPowerState == .connected)
        #expect(!snapshot.shouldSuppressPowerDeliveryWarnings)
        #expect(snapshot.hasSlowChargerCondition)
    }
}
