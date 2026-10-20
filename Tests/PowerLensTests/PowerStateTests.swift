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
    func lowInputRelativeToRatingIsObservedWithoutInferringItsCause() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: nil,
            batteryPowerW: 3.0,
            adapterInputPowerW: 20,
            systemLoadW: 21,
            adapterMaxPowerW: 97
        )

        #expect(snapshot.hasLowInputRelativeToAdapterRating)
    }

    @Test
    func highInputRelativeToRatingIsNotCalledLowInput() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: nil,
            batteryPowerW: -3.0,
            adapterInputPowerW: 60,
            systemLoadW: 61,
            adapterMaxPowerW: 97
        )

        #expect(!snapshot.hasLowInputRelativeToAdapterRating)
    }

    @Test
    func impossibleCurrentOnlyPowerBalanceCannotCorroborateAShortfall() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: -2.75,
            batteryPowerW: nil,
            adapterInputPowerW: 11.5,
            systemLoadW: 16.1,
            adapterMaxPowerW: 100
        )

        #expect(snapshot.hasConflictingDischargePowerBalance)
        #expect(!snapshot.hasCorroboratedPowerDeliveryShortfall)
    }

    @Test
    func missingVoltageMakesMateriallyMismatchedBatterySignalsUncorroborated() {
        let snapshot = makeTelemetrySnapshot(
            batteryVoltageV: nil,
            batteryCurrentA: -2.75,
            batteryPowerW: 0,
            batteryPowerSource: .directTelemetry,
            adapterInputPowerW: 11.5,
            systemLoadW: 16.1,
            adapterMaxPowerW: 100
        )

        #expect(snapshot.batteryFlowEvidence == .discharging)
        #expect(snapshot.measuredBatteryDischargeW == nil)
        #expect(snapshot.hasConflictingBatteryPowerMeasurements)
        #expect(!snapshot.hasCorroboratedPowerDeliveryShortfall)
    }

    @Test
    func missingVoltageKeepsCoherentDirectBatteryPowerCorroborated() {
        let snapshot = makeTelemetrySnapshot(
            batteryVoltageV: nil,
            batteryCurrentA: -1.5,
            batteryPowerW: 18,
            batteryPowerSource: .directTelemetry,
            adapterInputPowerW: 20,
            systemLoadW: 38,
            adapterMaxPowerW: 20
        )

        #expect(snapshot.batteryFlowEvidence == .discharging)
        #expect(snapshot.measuredBatteryDischargeW == 18)
        #expect(!snapshot.hasConflictingBatteryPowerMeasurements)
        #expect(!snapshot.hasConflictingDischargePowerBalance)
        #expect(snapshot.hasCorroboratedPowerDeliveryShortfall)
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
        #expect(snapshot.hasMaterialInputDeficit)
    }
}
