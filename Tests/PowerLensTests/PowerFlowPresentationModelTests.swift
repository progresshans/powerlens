import Testing
@testable import PowerLens

struct PowerFlowPresentationModelTests {
    @Test
    func directPowerPreservesRawInputAndLoadReadings() {
        let snapshot = makeTelemetrySnapshot(
            timeToEmptyMinutes: 60,
            adapterInputPowerW: 18.6,
            systemLoadW: 10.8
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .directPower)
        #expect(model.showsIndependentReadingsNotice)
        #expect(model.routes.map(\.role) == [.input])
        #expect(model.routes.first?.source.value == "18.6W")
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
        #expect(!model.showsIndependentReadingsNotice)
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
    func holdingKeepsSingleRawInputToSystemRoute() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: 0,
            batteryPowerW: 0,
            adapterInputPowerW: 11.7,
            systemLoadW: 11.7
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .holding)
        #expect(!model.showsIndependentReadingsNotice)
        #expect(model.routes.count == 1)
        #expect(model.routes.first?.role == .input)
        #expect(model.routes.first?.source.value == "11.7W")
        #expect(model.routes.first?.target.value == "11.7W")
    }

    @Test
    func coherentBatteryAssistMergesObservedReadings() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: -0.4,
            batteryPowerW: 3.8,
            adapterInputPowerW: 9.1,
            systemLoadW: 12.9
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .underpowered)
        #expect(!model.showsIndependentReadingsNotice)
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
    func calmBatteryDoesNotRewriteANonAtomicInputLoadPair() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: 0,
            batteryPowerW: 0,
            adapterInputPowerW: 20,
            systemLoadW: 38
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .holding)
        #expect(model.showsIndependentReadingsNotice)
        #expect(model.routes.map(\.role) == [.input])
        #expect(model.routes.first?.source.value == "20.0W")
        #expect(model.routes.first?.target.value == "38.0W")
    }

    @Test
    func measuredDischargeSurvivesABalancedInputLoadPair() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: -1.5,
            batteryPowerW: 18,
            adapterInputPowerW: 38,
            systemLoadW: 38
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .underpowered)
        #expect(model.showsIndependentReadingsNotice)
        #expect(model.routes.map(\.role) == [.input, .battery])
        #expect(model.routes[0].source.value == "38.0W")
        #expect(model.routes[1].source.value == "18.0W")
        #expect(model.routes[0].target.value == "38.0W")
    }

    @Test
    func measuredDischargeSurvivesInputAboveSystemLoad() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: -1.5,
            batteryPowerW: 18,
            adapterInputPowerW: 42,
            systemLoadW: 38
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .underpowered)
        #expect(model.routes.map(\.role) == [.input, .battery])
        #expect(model.routes[0].source.value == "42.0W")
        #expect(model.routes[1].source.value == "18.0W")
        #expect(model.routes[1].target.value == "38.0W")
    }

    @Test
    func dischargeCurrentWithNearZeroPowerUsesCurrentAndVoltage() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: -1,
            batteryPowerW: 0.1,
            adapterInputPowerW: 20,
            systemLoadW: 20
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(snapshot.hasConflictingBatteryPowerMeasurements)
        #expect(model.state == .underpowered)
        #expect(model.showsIndependentReadingsNotice)
        #expect(model.routes[0].source.value == "20.0W")
        #expect(model.routes[1].source.value == "≈12.2W")
        #expect(model.routes[1].target.value == "20.0W")
    }

    @Test
    func chargeCurrentWithNearZeroPowerUsesCurrentAndVoltage() {
        let snapshot = makeTelemetrySnapshot(
            isCharging: true,
            batteryCurrentA: 1,
            batteryPowerW: -0.1,
            adapterInputPowerW: 20,
            systemLoadW: 20
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(snapshot.hasConflictingBatteryPowerMeasurements)
        #expect(model.state == .charging)
        #expect(model.showsIndependentReadingsNotice)
        #expect(model.routes.map(\.role) == [.input, .charge])
        #expect(model.routes[0].source.value == "20.0W")
        #expect(model.routes[0].target.value == "20.0W")
        #expect(model.routes[1].target.value == "≈12.2W")
    }

    @Test
    func measuredChargeSurvivesInputBelowSystemLoad() {
        let snapshot = makeTelemetrySnapshot(
            isCharging: true,
            batteryCurrentA: 1,
            batteryPowerW: -0.1,
            adapterInputPowerW: 18,
            systemLoadW: 20
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .charging)
        #expect(model.routes.map(\.role) == [.input, .charge])
        #expect(model.routes[0].source.value == "18.0W")
        #expect(model.routes[0].target.value == "20.0W")
        #expect(model.routes[1].target.value == "≈12.2W")
    }

    @Test
    func dischargeDirectionSurvivesWhenItsWattageIsUnavailable() {
        let snapshot = makeTelemetrySnapshot(
            batteryVoltageV: nil,
            batteryCurrentA: -1,
            batteryPowerW: nil,
            adapterInputPowerW: 20,
            systemLoadW: 20
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(snapshot.batteryFlowEvidence == .discharging)
        #expect(snapshot.measuredBatteryDischargeW == nil)
        #expect(model.state == .underpowered)
        #expect(model.showsIndependentReadingsNotice)
        #expect(model.routes.map(\.role) == [.input, .battery])
        #expect(
            model.routes[1].source.value
                == L10n.text("common.none")
        )
    }

    @Test
    func chargeDirectionSurvivesWhenItsWattageIsUnavailable() {
        let snapshot = makeTelemetrySnapshot(
            isCharging: true,
            batteryVoltageV: nil,
            batteryCurrentA: 1,
            batteryPowerW: nil,
            adapterInputPowerW: 20,
            systemLoadW: 20
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(snapshot.batteryFlowEvidence == .charging)
        #expect(snapshot.measuredBatteryChargeW == nil)
        #expect(model.state == .charging)
        #expect(model.showsIndependentReadingsNotice)
        #expect(model.routes.map(\.role) == [.input, .charge])
        #expect(
            model.routes[1].target.value
                == L10n.text("common.none")
        )
    }

    @Test
    func coherentChargingSplitsObservedInputToLoadAndBattery() {
        let snapshot = makeTelemetrySnapshot(
            isCharging: true,
            batteryCurrentA: 3.44,
            batteryPowerW: -46.4,
            adapterInputPowerW: 53.6,
            systemLoadW: 7.2
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .charging)
        #expect(!model.showsIndependentReadingsNotice)
        #expect(model.routes.map(\.role) == [.input, .charge])
        #expect(model.routes[0].source.value == "53.6W")
        #expect(model.routes[1].source.value == "53.6W")
        #expect(model.routes[0].target.value == "7.2W")
        #expect(model.routes[1].target.value == "46.4W")
    }

    @Test
    func batteryOnlyShowsObservedBatteryAndSystemReadings() {
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
        #expect(!model.showsIndependentReadingsNotice)
        #expect(model.routes.map(\.role) == [.battery])
        #expect(model.routes.first?.source.value == "9.1W")
        #expect(model.routes.first?.target.value == "9.1W")
    }

    @Test
    func oppositeDirectBatteryDirectionsRemainUnknown() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: 1,
            batteryPowerW: 5,
            adapterInputPowerW: 20,
            systemLoadW: 20
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(snapshot.batteryFlowEvidence == .conflicted)
        #expect(model.state == .unknown)
        #expect(model.statusTitle == L10n.text("ui.flow.unknown"))
        #expect(model.showsIndependentReadingsNotice)
        #expect(model.routes.map(\.role) == [.input])
        #expect(model.routes.first?.source.value == "20.0W")
        #expect(model.routes.first?.target.value == "20.0W")
    }

    @Test
    func chargingFlagAloneDoesNotCreateAZeroPowerChargeRoute() {
        let snapshot = makeTelemetrySnapshot(
            isCharging: true,
            batteryCurrentA: nil,
            batteryPowerW: nil,
            adapterInputPowerW: 20,
            systemLoadW: 20
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(snapshot.batteryFlowEvidence == .charging)
        #expect(model.state == .directPower)
        #expect(model.routes.map(\.role) == [.input])
    }

    @Test
    func chargingFlagFallbackKeepsTheResidualNoiseGuard() {
        let belowNoiseFloor = makeTelemetrySnapshot(
            isCharging: true,
            batteryCurrentA: nil,
            batteryPowerW: nil,
            adapterInputPowerW: 20.2,
            systemLoadW: 20
        )
        let materialResidual = makeTelemetrySnapshot(
            isCharging: true,
            batteryCurrentA: nil,
            batteryPowerW: nil,
            adapterInputPowerW: 20.5,
            systemLoadW: 20
        )

        let belowNoiseModel = PowerFlowPresentationModel(
            snapshot: belowNoiseFloor
        )
        let materialModel = PowerFlowPresentationModel(
            snapshot: materialResidual
        )

        #expect(belowNoiseModel.state == .directPower)
        #expect(belowNoiseModel.routes.map(\.role) == [.input])
        #expect(materialModel.state == .charging)
        #expect(materialModel.showsIndependentReadingsNotice)
        #expect(materialModel.routes.map(\.role) == [.input, .charge])
        #expect(materialModel.routes[1].target.value == "≈0.5W")
    }

    @Test
    func missingDirectBatterySensorsCanStillUseTheLoadResidualFallback() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: nil,
            batteryPowerW: nil,
            adapterInputPowerW: 10,
            systemLoadW: 11
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(snapshot.batteryFlowEvidence == .unavailable)
        #expect(model.state == .underpowered)
        #expect(model.showsIndependentReadingsNotice)
        #expect(model.routes.map(\.role) == [.input, .battery])
        #expect(model.routes[0].source.value == "10.0W")
        #expect(model.routes[1].source.value == "≈1.0W")
        #expect(model.routes[1].target.value == "11.0W")
    }
}
