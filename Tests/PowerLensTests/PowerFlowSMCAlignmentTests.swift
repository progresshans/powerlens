import Testing
@testable import PowerLens

struct PowerFlowSMCAlignmentTests {
    struct TransientSample: Sendable {
        let batteryW: Double
        let inputW: Double
        let systemW: Double
        let state: PowerFlowDiagramState
        let shownInput: String
        let shownBattery: String
        let shownSystem: String
    }

    /// SMC samples captured at 20 Hz while a charger was connected. The
    /// registry battery current stayed at -1.196 A (discharging) for more than
    /// 15 seconds while SMC battery power turned to charging.
    @Test(arguments: [
        TransientSample(batteryW: 17.975, inputW: 14.530, systemW: 20.445, state: .underpowered,
                        shownInput: "2.4W", shownBattery: "18.0W", shownSystem: "20.4W"),
        TransientSample(batteryW: 5.117, inputW: 31.686, systemW: 19.647, state: .underpowered,
                        shownInput: "14.5W", shownBattery: "5.1W", shownSystem: "19.6W"),
        TransientSample(batteryW: -9.093, inputW: 31.686, systemW: 19.647, state: .charging,
                        shownInput: "28.7W", shownBattery: "9.1W", shownSystem: "19.6W"),
        TransientSample(batteryW: -16.756, inputW: 37.393, systemW: 22.039, state: .charging,
                        shownInput: "38.8W", shownBattery: "16.8W", shownSystem: "22.0W"),
    ])
    func chargerConnectionUsesTheSmcBatterySignAndTheSystemAnchor(sample: TransientSample) {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: -1.196,
            batteryPowerW: sample.batteryW,
            batteryPowerSource: .directTelemetry,
            adapterInputPowerW: sample.inputW,
            systemLoadW: sample.systemW,
            powerMeasurementSetSource: .smc
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)
        let tooltip = PowerFlowTooltip.text(snapshot: snapshot, readings: readings)

        #expect(model.state == sample.state)
        #expect(model.connectionStyle == .solid)
        #expect(readings.inputPower?.formatted == sample.shownInput)
        #expect(readings.batteryPower?.formatted == sample.shownBattery)
        #expect(readings.systemPower?.formatted == sample.shownSystem)
        #expect(readings.batteryPower?.isApproximate == false)
        #expect(readings.inputAdjustment == nil)
        #expect(tooltip.contains(L10n.text("ui.flow.tooltip.smcTiming")))
        #expect(tooltip.contains(L10n.text("ui.flow.tooltip.inputFromAnchor")))
        // The direction note appears only where the stale current disagrees.
        #expect(
            tooltip.contains(L10n.tr("ui.flow.tooltip.smcDirection", "-1.196A"))
                == (sample.state == .charging)
        )
        #expect(snapshot.adapterInputPowerW == sample.inputW)
        #expect(snapshot.batteryPowerW == sample.batteryW)
    }

    @Test
    func unpluggedSmcSetUsesTheBatterySignOverAStaleChargeCurrent() {
        let snapshot = makeTelemetrySnapshot(
            powerSource: .battery, externalConnected: false,
            batteryCurrentA: 1.5, batteryPowerW: 12,
            batteryPowerSource: .directTelemetry,
            adapterInputPowerW: 0, systemLoadW: 12,
            powerMeasurementSetSource: .smc
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(snapshot.batteryFlowEvidence == .conflicted)
        #expect(readings.smcBatteryDirection == .discharging)
        #expect(model.state == .discharging)
        #expect(model.connectionStyle == .solid)
        #expect(model.routes.first?.source.value == "12.0W")
        #expect(model.routes.first?.target.value == "12.0W")
        #expect(
            PowerFlowTooltip.text(snapshot: snapshot, readings: readings)
                .contains(L10n.tr("ui.flow.tooltip.smcDirection", "1.5A"))
        )
    }

    @Test
    func unpluggedSmcSetStillRejectsAChargingBatterySign() {
        let snapshot = makeTelemetrySnapshot(
            powerSource: .battery, externalConnected: false,
            batteryCurrentA: -0.5, batteryPowerW: -6,
            batteryPowerSource: .directTelemetry,
            adapterInputPowerW: 0, systemLoadW: 10,
            powerMeasurementSetSource: .smc
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)
        let tooltip = PowerFlowTooltip.text(snapshot: snapshot, readings: readings)

        #expect(readings.smcBatteryDirection == .charging)
        #expect(readings.fallbackReason == .conflictingDirection)
        #expect(readings.candidateSystemPower == nil)
        #expect(readings.candidateSystemPowerW == nil)
        #expect(readings.discrepancyW == nil)
        #expect(model.state == .unknown)
        #expect(model.connectionStyle == .hidden)
        #expect(model.routes.map(\.role) == [.battery])
        #expect(model.routes.first?.source.value == L10n.text("common.none"))
        #expect(model.routes.first?.target.value == "10.0W")
        #expect(tooltip.contains(L10n.tr(
            "ui.flow.tooltip.rawBattery",
            L10n.tr("format.batteryPower.charging", "6.0W")
        )))
        #expect(!tooltip.contains(L10n.tr(
            "ui.flow.tooltip.observedBalance",
            L10n.tr("ui.flow.tooltip.expression.battery", "6.0W"),
            "6.0W"
        )))
        #expect(!tooltip.contains(L10n.tr(
            "ui.flow.tooltip.observedBalanceDifference", "4.0W"
        )))
        #expect(snapshot.batteryPowerW == -6)
        #expect(snapshot.batteryCurrentA == -0.5)
    }

    @Test
    func calculatedChargingInputIsLimitedToTheAdapterRating() {
        let snapshot = makeTelemetrySnapshot(
            isCharging: true, batteryVoltageV: 12.5, batteryCurrentA: 0.96,
            batteryPowerW: -12, batteryPowerSource: .directTelemetry,
            adapterInputPowerW: 20, systemLoadW: 15, adapterMaxPowerW: 20
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let tooltip = PowerFlowTooltip.text(snapshot: snapshot, readings: readings)

        #expect(readings.state == .charging)
        #expect(readings.hasBalancedFlow)
        #expect(readings.inputAdjustment == .limitedToAdapterRating)
        #expect(readings.inputPower?.formatted == "20.0W")
        #expect(readings.batteryPower == DisplayedPowerMeasurement(watts: 5, isApproximate: true))
        #expect(readings.systemPower?.formatted == "15.0W")
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.adjust.inputRating", "20.0W")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.displayCharging", "20.0W", "15.0W", "5.0W")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.adjustedBatteryCharge", "5.0W")))
        #expect(snapshot.batteryPowerW == -12)
    }

    @Test
    func chargingWithTheSystemAnchorAboveTheAdapterRatingHidesTheRoute() {
        let snapshot = makeTelemetrySnapshot(
            isCharging: true, batteryVoltageV: 12.5, batteryCurrentA: 0.4,
            batteryPowerW: -5, batteryPowerSource: .directTelemetry,
            adapterInputPowerW: 20, systemLoadW: 21, adapterMaxPowerW: 20
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(readings.fallbackReason == .invalidBalance)
        #expect(readings.inputAdjustment == nil)
        #expect(model.connectionStyle == .hidden)
        #expect(model.routes.first?.source.value == L10n.text("common.none"))
        #expect(model.routes.first?.target.value == "21.0W")
    }

    @Test
    func calculatedAssistInputIsLimitedToTheAdapterRating() {
        let snapshot = makeTelemetrySnapshot(
            batteryVoltageV: 12.5, batteryCurrentA: -0.4,
            batteryPowerW: 5, batteryPowerSource: .directTelemetry,
            adapterInputPowerW: 28.5, systemLoadW: 45, adapterMaxPowerW: 30
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let tooltip = PowerFlowTooltip.text(snapshot: snapshot, readings: readings)

        #expect(readings.state == .underpowered)
        #expect(readings.inputAdjustment == .limitedToAdapterRating)
        #expect(readings.inputPower?.formatted == "30.0W")
        #expect(readings.batteryPower == DisplayedPowerMeasurement(watts: 15, isApproximate: true))
        #expect(readings.systemPower?.formatted == "45.0W")
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.adjust.inputRating", "30.0W")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.displayAssist", "30.0W", "15.0W", "45.0W")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.adjustedBatteryAssist", "15.0W")))
    }

    @Test
    func negativeCalculatedAssistInputIsShownAsZeroWithAnExplanation() {
        let snapshot = makeTelemetrySnapshot(
            batteryVoltageV: 12, batteryCurrentA: 0,
            batteryPowerW: 9, batteryPowerSource: .directTelemetry,
            adapterInputPowerW: 1, systemLoadW: 2
        )
        let tooltip = PowerFlowTooltip.text(snapshot: snapshot)

        #expect(tooltip.contains(L10n.text("ui.flow.tooltip.adjust.inputFloor")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.displayAssist", "0.0W", "2.0W", "2.0W")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.adjustedBatteryAssist", "2.0W")))
    }

    @Test
    func aZeroSystemAnchorCannotCarryABatteryAssistRoute() {
        let snapshot = makeTelemetrySnapshot(
            batteryVoltageV: 12, batteryCurrentA: 0,
            batteryPowerW: 1, batteryPowerSource: .directTelemetry,
            adapterInputPowerW: 1, systemLoadW: 0
        )
        let readings = PowerFlowReadings(snapshot: snapshot)

        #expect(readings.state == .underpowered)
        #expect(readings.fallbackReason == .invalidBalance)
        #expect(readings.inputAdjustment == nil)
        #expect(readings.systemPower?.formatted == "0.0W")
    }

    @Test(arguments: [0.36, 0.34, 0.0])
    func adapterRatingStillAppliesWhenSmcBatteryPowerBecomesCalm(batteryW: Double) throws {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: 0, batteryPowerW: batteryW,
            batteryPowerSource: .directTelemetry,
            adapterInputPowerW: 28.5, systemLoadW: 45,
            powerMeasurementSetSource: .smc, adapterMaxPowerW: 30
        )
        let originalShortfall = snapshot.hasCorroboratedPowerDeliveryShortfall
        let originalDiagnostics = snapshot.diagnostics
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)
        let tooltip = PowerFlowTooltip.text(snapshot: snapshot, readings: readings)

        #expect(readings.observedState == (batteryW > 0.35 ? .underpowered : .holding))
        #expect(readings.state == .underpowered)
        #expect(readings.hasBalancedFlow)
        #expect(readings.inputAdjustment == .limitedToAdapterRating)
        #expect(readings.inputPower?.formatted == "30.0W")
        #expect(readings.batteryPower == DisplayedPowerMeasurement(watts: 15, isApproximate: true))
        #expect(readings.systemPower == DisplayedPowerMeasurement(watts: 45, isApproximate: false))
        #expect(model.state == .underpowered)
        #expect(model.connectionStyle == .solid)
        #expect(model.routes.map(\.role) == [.input, .battery])
        #expect(model.routes.allSatisfy { $0.target.value == "45.0W" })
        let input = try #require(readings.inputPower)
        let battery = try #require(readings.batteryPower)
        let system = try #require(readings.systemPower)
        #expect(Int((input.watts * 10).rounded()) + Int((battery.watts * 10).rounded())
                == Int((system.watts * 10).rounded()))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.adjust.inputRating", "30.0W")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.adjustedBatteryAssist", "15.0W")))
        #expect(snapshot.adapterInputPowerW == 28.5)
        #expect(snapshot.batteryPowerW == batteryW)
        #expect(snapshot.systemLoadW == 45)
        #expect(snapshot.hasCorroboratedPowerDeliveryShortfall == originalShortfall)
        let currentDiagnostics = snapshot.diagnostics
        #expect(currentDiagnostics.map(\.kind) == originalDiagnostics.map(\.kind))
        #expect(currentDiagnostics.map(\.severity) == originalDiagnostics.map(\.severity))
        #expect(currentDiagnostics.map(\.title) == originalDiagnostics.map(\.title))
        #expect(currentDiagnostics.map(\.message) == originalDiagnostics.map(\.message))
        if batteryW <= 0.35 {
            #expect(readings.observedBatteryPowerW == nil)
            #expect(readings.candidateSystemPowerW == 28.5)
            #expect(readings.discrepancyW == 16.5)
            #expect(tooltip.contains(L10n.tr(
                "ui.flow.tooltip.observedBalance",
                L10n.tr("ui.flow.tooltip.expression.input", "28.5W"),
                "28.5W"
            )))
        }
    }

    @Test
    func calmDirectPowerAboveTheRatingUsesAnExplicitCalculatedBatteryBranch() {
        let snapshot = makeTelemetrySnapshot(
            timeToEmptyMinutes: 60,
            batteryCurrentA: 0, batteryPowerW: 0,
            adapterInputPowerW: 28.5, systemLoadW: 45, adapterMaxPowerW: 30
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(readings.observedState == .directPower)
        #expect(readings.state == .underpowered)
        #expect(readings.inputAdjustment == .limitedToAdapterRating)
        #expect(readings.inputPower?.formatted == "30.0W")
        #expect(readings.batteryPower == DisplayedPowerMeasurement(watts: 15, isApproximate: true))
        #expect(model.connectionStyle == .solid)
        #expect(model.routes.map(\.role) == [.input, .battery])
        #expect(snapshot.batteryPowerW == 0)
    }

    @Test(arguments: [0.36, 0.34, 0.0])
    func calmTransitionWithinTheRatingKeepsTheObservedDisplayPolicy(batteryW: Double) {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: 0, batteryPowerW: batteryW,
            batteryPowerSource: .directTelemetry,
            adapterInputPowerW: 20, systemLoadW: 20,
            powerMeasurementSetSource: .smc, adapterMaxPowerW: 30
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(readings.inputAdjustment == nil)
        #expect(readings.state == readings.observedState)
        #expect(model.connectionStyle == .solid)
        #expect(readings.systemPower?.formatted == "20.0W")
        if batteryW > 0.35 {
            #expect(readings.state == .underpowered)
            #expect(readings.inputPower?.formatted == "19.6W")
            #expect(readings.batteryPower == DisplayedPowerMeasurement(watts: 0.4, isApproximate: false))
        } else {
            #expect(readings.state == .holding)
            #expect(readings.inputPower?.formatted == "20.0W")
            #expect(readings.batteryPower == nil)
            #expect(model.routes.map(\.role) == [.input])
        }
    }

    @Test(arguments: [30.0, 30.04])
    func calmSystemAtTheDisplayedRatingDoesNotAddABatteryBranch(systemW: Double) {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: 0, batteryPowerW: 0,
            adapterInputPowerW: 28.5, systemLoadW: systemW,
            powerMeasurementSetSource: .smc, adapterMaxPowerW: 30
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(readings.state == .holding)
        #expect(readings.inputPower?.formatted == "30.0W")
        #expect(readings.systemPower?.formatted == "30.0W")
        #expect(readings.batteryPower == nil)
        #expect(readings.inputAdjustment == nil)
        #expect(model.connectionStyle == .solid)
        #expect(model.routes.map(\.role) == [.input])
    }

    @Test(arguments: [nil, 0.0, -1.0, Double.nan, Double.infinity, -Double.infinity] as [Double?])
    func calmFlowWithoutAUsableRatingKeepsTheSystemAnchor(ratingW: Double?) {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: 0, batteryPowerW: 0,
            adapterInputPowerW: 28.5, systemLoadW: 45,
            powerMeasurementSetSource: .smc, adapterMaxPowerW: ratingW
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(readings.state == .holding)
        #expect(readings.inputPower?.formatted == "45.0W")
        #expect(readings.systemPower?.formatted == "45.0W")
        #expect(readings.batteryPower == nil)
        #expect(readings.inputAdjustment == nil)
        #expect(model.connectionStyle == .solid)
        #expect(model.routes.map(\.role) == [.input])
    }
}
