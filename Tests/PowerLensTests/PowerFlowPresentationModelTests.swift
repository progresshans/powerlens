import Testing
@testable import PowerLens

struct PowerFlowPresentationModelTests {
    @Test
    func directPowerUsesOnlyInputToSystemRoute() {
        let snapshot = makeTelemetrySnapshot(
            timeToEmptyMinutes: 60,
            adapterInputPowerW: 18.6,
            systemLoadW: 10.8
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .directPower)
        #expect(model.externalToSystemPower == 10.8)
        #expect(model.batteryToSystemPower == 0)
        #expect(model.externalToBatteryPower == 0)
        #expect(model.usesEstimatedContributions)
        #expect(model.routes.map(\.role) == [.input])
        #expect(model.routes.first?.source.value == "≈10.8W")
        #expect(model.routes.first?.target.value == "10.8W")
    }

    @Test
    func missingPowerMeasurementsRemainUnknownInTheRoute() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: nil,
            batteryPowerW: nil,
            adapterInputPowerW: nil,
            systemLoadW: nil
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .directPower)
        #expect(
            model.routes.first?.source.value
                == L10n.text("common.none")
        )
        #expect(
            model.routes.first?.target.value
                == L10n.text("common.none")
        )
    }

    @Test
    func holdingKeepsSingleInputToSystemRoute() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: 0,
            batteryPowerW: 0,
            adapterInputPowerW: 11.7,
            systemLoadW: 11.7
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .holding)
        #expect(!model.usesEstimatedContributions)
        #expect(model.routes.count == 1)
        #expect(model.routes.first?.role == .input)
        #expect(model.routes.first?.source.value == "11.7W")
        #expect(model.routes.first?.target.value == "11.7W")
    }

    @Test
    func underpoweredMergesInputAndBatteryIntoSystemLoad() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: -0.4,
            batteryPowerW: 3.8,
            adapterInputPowerW: 9.1,
            systemLoadW: 12.9
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .underpowered)
        #expect(abs(model.externalToSystemPower - 9.1) < 0.0001)
        #expect(abs(model.batteryToSystemPower - 3.8) < 0.0001)
        #expect(!model.usesEstimatedContributions)
        #expect(model.routes.map(\.role) == [.input, .battery])
        #expect(model.routes[0].source.value == "9.1W")
        #expect(model.routes[1].source.value == "3.8W")
        #expect(model.routes[1].target.value == "12.9W")
    }

    @Test
    func managedPolicyAndStaleChargingFlagDoNotOverwriteBatteryAssist() {
        let snapshot = makeTelemetrySnapshot(
            batteryLevel: 80,
            isCharging: true,
            batteryCurrentA: -1.5,
            batteryPowerW: 18,
            adapterInputPowerW: 20,
            systemLoadW: 38,
            adapterMaxPowerW: 96,
            chargingPolicyStatus: .manualLimit(targetPercent: 80)
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .underpowered)
        #expect(model.statusTitle == L10n.text("ui.flow.batteryAssist"))
        #expect(model.routes.map(\.role) == [.input, .battery])
    }

    @Test
    func calmBatteryMeasurementOverridesANonAtomicInputLoadDeficit() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: 0,
            batteryPowerW: 0,
            adapterInputPowerW: 20,
            systemLoadW: 38
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .holding)
        #expect(model.batteryAssist == 0)
        #expect(model.externalToSystemPower == 38)
        #expect(model.usesEstimatedContributions)
        #expect(model.routes.map(\.role) == [.input])
        #expect(model.routes.first?.source.value == "≈38.0W")
        #expect(model.routes.first?.target.value == "38.0W")
    }

    @Test
    func measuredDischargeOverridesANonAtomicBalancedInputLoadPair() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: -1.5,
            batteryPowerW: 18,
            adapterInputPowerW: 38,
            systemLoadW: 38
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .underpowered)
        #expect(model.batteryAssist == 18)
        #expect(model.externalToSystemPower == 20)
        #expect(model.batteryToSystemPower == 18)
        #expect(model.usesEstimatedContributions)
        #expect(model.routes.map(\.role) == [.input, .battery])
        #expect(model.routes[0].source.value == "≈20.0W")
        #expect(model.routes[1].source.value == "18.0W")
    }

    @Test
    func materialDischargeCurrentWithNearZeroPowerUsesResidualEstimate() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: -1,
            batteryPowerW: 0.1,
            adapterInputPowerW: 20,
            systemLoadW: 32.25
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .underpowered)
        #expect(abs(model.batteryAssist - 12.25) < 0.0001)
        #expect(abs(model.batteryToSystemPower - 12.25) < 0.0001)
        #expect(model.usesEstimatedContributions)
        #expect(model.routes[1].source.value == "≈12.2W")
    }

    @Test
    func materialChargeCurrentWithNearZeroPowerUsesResidualEstimate() {
        let snapshot = makeTelemetrySnapshot(
            isCharging: true,
            batteryCurrentA: 1,
            batteryPowerW: -0.1,
            adapterInputPowerW: 32.25,
            systemLoadW: 20
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .charging)
        #expect(abs(model.chargePower - 12.25) < 0.0001)
        #expect(abs(model.externalToBatteryPower - 12.25) < 0.0001)
        #expect(model.usesEstimatedContributions)
        #expect(model.routes[1].target.value == "≈12.2W")
    }

    @Test
    func chargingSplitsInputIntoSystemAndBatteryCharge() {
        let snapshot = makeTelemetrySnapshot(
            isCharging: true,
            batteryCurrentA: 3.44,
            batteryPowerW: -46.4,
            adapterInputPowerW: 53.6,
            systemLoadW: 7.2
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .charging)
        #expect(model.externalToSystemPower == 7.2)
        #expect(model.externalToBatteryPower == 46.4)
        #expect(model.batteryToSystemPower == 0)
        #expect(!model.usesEstimatedContributions)
        #expect(model.routes.map(\.role) == [.input, .charge])
        #expect(model.routes[0].source.value == "53.6W")
        #expect(model.routes[1].source.value == "53.6W")
        #expect(model.routes[0].target.value == "7.2W")
        #expect(model.routes[1].target.value == "46.4W")
    }

    @Test
    func batteryOnlyShowsBatteryToSystemLoad() {
        let snapshot = makeTelemetrySnapshot(
            powerSource: .battery,
            externalConnected: false,
            timeToEmptyMinutes: 240,
            batteryCurrentA: -0.82,
            batteryPowerW: 9.1,
            adapterInputPowerW: 0,
            systemLoadW: 9.1,
            adapterMaxPowerW: nil
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .discharging)
        #expect(model.inputPower == 0)
        #expect(model.batteryToSystemPower == 9.1)
        #expect(!model.usesEstimatedContributions)
        #expect(model.routes.map(\.role) == [.battery])
        #expect(model.routes.first?.source.value == "9.1W")
        #expect(model.routes.first?.target.value == "9.1W")
    }

    @Test
    func inconsistentBatterySensorsUseABalancedEstimatedAssist() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: -2.75,
            batteryPowerW: 0,
            adapterInputPowerW: 11.5,
            systemLoadW: 16.1
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(snapshot.hasConflictingBatteryPowerMeasurements)
        #expect(model.state == .underpowered)
        #expect(abs(model.externalToSystemPower - 11.5) < 0.0001)
        #expect(abs(model.batteryToSystemPower - 4.6) < 0.0001)
        #expect(
            abs(
                model.externalToSystemPower
                    + model.batteryToSystemPower
                    - model.loadPower
            ) < 0.0001
        )
        #expect(model.usesEstimatedContributions)
        #expect(model.routes[0].source.value == "11.5W")
        #expect(model.routes[1].source.value == "≈4.6W")
        #expect(model.routes[1].target.value == "16.1W")
    }

    @Test
    func impossibleCurrentOnlyBalanceAlsoUsesTheResidualEstimate() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: -2.75,
            batteryPowerW: nil,
            adapterInputPowerW: 11.5,
            systemLoadW: 16.1
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(!snapshot.hasConflictingBatteryPowerMeasurements)
        #expect(snapshot.hasConflictingDischargePowerBalance)
        #expect(abs(model.batteryToSystemPower - 4.6) < 0.0001)
        #expect(model.routes[1].source.value == "≈4.6W")
        #expect(model.usesEstimatedContributions)
    }
}
