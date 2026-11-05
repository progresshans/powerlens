import Testing
@testable import PowerLens

struct PowerFlowQualityTests {
    @Test(arguments: [true, false])
    func batteryCurrentFallbackTooltipExplainsTheActualSelectedBranch(charging: Bool) {
        let snapshot = makeTelemetrySnapshot(
            isCharging: charging,
            batteryVoltageV: 12.25,
            batteryCurrentA: charging ? 1 : -1,
            batteryPowerW: charging ? -0.1 : 0.1,
            adapterInputPowerW: 20,
            systemLoadW: charging ? 7.75 : 32.25
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let tooltip = PowerFlowTooltip.text(snapshot: snapshot, readings: readings)
        let direction = charging ? "format.batteryPower.charging" : "format.batteryPower.discharging"

        #expect(readings.hasBalancedFlow)
        #expect(readings.systemPowerSource == .measured)
        #expect(readings.batteryValueSource == .currentAndVoltage)
        #expect(readings.observedBatteryPowerW == 12.25)
        #expect(tooltip.contains(L10n.tr(
            "ui.flow.tooltip.batteryCurrentVoltageCalculation",
            charging ? "1.0A" : "-1.0A", "12.25V",
            L10n.tr(direction, "12.25W")
        )))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.rawBattery", L10n.tr(direction, "0.1W"))))
    }

    @Test(arguments: [true, false])
    func inferredBatteryTooltipUsesTheCorrectSubtractionOrder(charging: Bool) {
        let snapshot = makeTelemetrySnapshot(
            isCharging: charging,
            batteryCurrentA: nil,
            batteryPowerW: nil,
            adapterInputPowerW: 20,
            systemLoadW: charging ? 19 : 21
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let tooltip = PowerFlowTooltip.text(snapshot: snapshot, readings: readings)
        let input = L10n.tr("ui.flow.tooltip.expression.input", "20.0W")
        let system = "\(L10n.text("ui.metric.systemLoad")) \(charging ? "19.0W" : "21.0W")"
        let direction = charging ? "format.batteryPower.charging" : "format.batteryPower.discharging"

        #expect(readings.hasBalancedFlow)
        #expect(readings.batteryValueSource == .inputLoadDifference)
        #expect(tooltip.contains(L10n.tr(
            "ui.flow.tooltip.batteryResidualCalculation",
            charging ? input : system, charging ? system : input,
            L10n.tr(direction, "1.0W")
        )))
    }

    struct ObservedExample: Sendable {
        let inputW: Double
        let batteryW: Double
        let rawSystemW: Double
        let candidateW: Double
        let discrepancyW: Double
        let state: PowerFlowDiagramState
        let displayedInput: String
        let displayedBattery: String?
        let displayedSystem: String
    }

    @Test(arguments: [
        ObservedExample(
            inputW: 53.277, batteryW: 6.393, rawSystemW: 6.46,
            candidateW: 59.67, discrepancyW: 53.21, state: .underpowered,
            displayedInput: "0.1W", displayedBattery: "6.4W", displayedSystem: "6.5W"
        ),
        ObservedExample(
            inputW: 22.277, batteryW: 5.741, rawSystemW: 35.005,
            candidateW: 28.018, discrepancyW: 6.987, state: .underpowered,
            displayedInput: "29.3W", displayedBattery: "5.7W", displayedSystem: "35.0W"
        ),
        ObservedExample(
            inputW: 18.474, batteryW: 0.1, rawSystemW: 12.635,
            candidateW: 18.474, discrepancyW: 5.839, state: .holding,
            displayedInput: "12.6W", displayedBattery: nil, displayedSystem: "12.6W"
        ),
    ])
    func observedDiscrepanciesDoNotSwitchTheSystemAnchorOrChangeRawTelemetry(example: ObservedExample) throws {
        let snapshot = makeTelemetrySnapshot(
            batteryVoltageV: 12,
            batteryCurrentA: example.state == .holding ? 0 : -example.batteryW / 12,
            batteryPowerW: example.batteryW,
            batteryPowerSource: .directTelemetry,
            adapterInputPowerW: example.inputW,
            systemLoadW: example.rawSystemW
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)
        let candidateW = try #require(readings.candidateSystemPowerW)
        let discrepancyW = try #require(readings.discrepancyW)

        #expect(readings.hasBalancedFlow)
        #expect(readings.fallbackReason == nil)
        #expect(readings.systemPowerSource == .measured)
        #expect(abs(candidateW - example.candidateW) < 0.000_001)
        #expect(abs(discrepancyW - example.discrepancyW) < 0.000_001)
        #expect(readings.systemPower?.formatted == example.displayedSystem)
        #expect(readings.systemPower?.isApproximate == false)
        #expect(readings.inputPower?.formatted == example.displayedInput)
        #expect(readings.batteryPower?.formatted == example.displayedBattery)
        #expect(model.state == example.state)
        #expect(model.connectionStyle == .solid)
        #expect(model.routes.first?.source.value == example.displayedInput)
        #expect(model.routes.allSatisfy { $0.target.value == example.displayedSystem })
        #expect(snapshot.menuBarTitle == "80% · \(example.displayedSystem)")
        #expect(model.routes.allSatisfy { !$0.source.value.contains("≈") && !$0.target.value.contains("≈") })

        let details = Dictionary(uniqueKeysWithValues: TelemetryDetailRows.powerSnapshot(snapshot))
        #expect(details[L10n.text("ui.metric.systemLoad")] == Formatters.power(example.rawSystemW))
        #expect(snapshot.adapterInputPowerW == example.inputW)
        #expect(snapshot.batteryPowerW == example.batteryW)
        #expect(snapshot.systemLoadW == example.rawSystemW)
        #expect(snapshot.withChargingPolicyStatus(nil).systemLoadW == example.rawSystemW)
    }

    @Test(arguments: [0.0, 6.999, 7.0, 12.999, 13.0, 13.001, 84.999, 115.001])
    func changingTheOriginalInputNeverSwitchesAValidSystemAnchor(inputW: Double) {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: 0,
            batteryPowerW: 0,
            adapterInputPowerW: inputW,
            systemLoadW: 10
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(readings.candidateSystemPowerW == inputW)
        #expect(readings.systemPower == DisplayedPowerMeasurement(watts: 10, isApproximate: false))
        #expect(readings.inputPower?.watts == 10)
        #expect(readings.systemPowerSource == .measured)
        #expect(readings.hasBalancedFlow)
        #expect(readings.fallbackReason == nil)
        #expect(model.state == .holding)
        #expect(model.connectionStyle == .solid)
        #expect(snapshot.adapterInputPowerW == inputW)
    }

    @Test
    func chargingUsesTheSystemAnchorPlusObservedChargeForDisplayedInput() {
        let snapshot = makeTelemetrySnapshot(
            isCharging: true,
            batteryVoltageV: 12,
            batteryCurrentA: 1,
            batteryPowerW: -12,
            adapterInputPowerW: 22,
            systemLoadW: 20
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(readings.candidateSystemPowerW == 10)
        #expect(readings.discrepancyW == 10)
        #expect(readings.hasBalancedFlow)
        #expect(readings.fallbackReason == nil)
        #expect(readings.inputPower?.watts == 32)
        #expect(readings.batteryPower?.watts == 12)
        #expect(readings.systemPower?.watts == 20)
        #expect(model.state == .charging)
        #expect(model.connectionStyle == .solid)
        #expect(model.routes.map(\.role) == [.input, .charge])
        #expect(snapshot.menuBarTitle == "80% · 20.0W")
        #expect(snapshot.adapterInputPowerW == 22)
        #expect(snapshot.batteryPowerW == -12)
    }

    @Test(arguments: [nil, 15.0] as [Double?])
    func negativeObservedBalanceNeedsASystemAnchorAndIsNeverClamped(rawSystemW: Double?) {
        let snapshot = makeTelemetrySnapshot(
            isCharging: true,
            batteryVoltageV: 12,
            batteryCurrentA: 1,
            batteryPowerW: -12,
            adapterInputPowerW: 10,
            systemLoadW: rawSystemW
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(readings.candidateSystemPowerW == -2)
        #expect(readings.candidateSystemPower == nil)
        #expect(readings.systemPower?.watts == rawSystemW)
        if rawSystemW != nil {
            #expect(readings.hasBalancedFlow)
            #expect(readings.fallbackReason == nil)
            #expect(readings.systemPowerSource == .measured)
            #expect(readings.inputPower?.watts == 27)
            #expect(readings.batteryPower?.watts == 12)
            #expect(model.state == .charging)
            #expect(model.connectionStyle == .solid)
        } else {
            #expect(!readings.hasBalancedFlow)
            #expect(readings.fallbackReason == .invalidBalance)
            #expect(readings.systemPowerSource == .unavailable)
            #expect(model.state == .unknown)
            #expect(model.connectionStyle == .hidden)
            #expect(model.routes.count == 1)
            #expect(model.routes.first?.source.value == L10n.text("common.none"))
            #expect(model.routes.first?.target.value == L10n.text("common.none"))
        }
    }

    @Test(arguments: [nil, Double.nan, Double.infinity, -1.0] as [Double?])
    func absentOrInvalidSystemSensorUsesAValidOriginalBalance(rawSystemW: Double?) {
        let snapshot = makeTelemetrySnapshot(
            isCharging: true,
            batteryVoltageV: 12,
            batteryCurrentA: 1,
            batteryPowerW: -12,
            adapterInputPowerW: 22,
            systemLoadW: rawSystemW
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(readings.candidateSystemPowerW == 10)
        #expect(readings.systemPower == DisplayedPowerMeasurement(watts: 10, isApproximate: true))
        #expect(readings.systemPowerSource == .powerBalance)
        #expect(readings.discrepancyW == nil)
        #expect(readings.hasBalancedFlow)
        #expect(readings.fallbackReason == nil)
        #expect(model.state == .charging)
        #expect(model.connectionStyle == .solid)
        #expect(model.routes.first?.source.value == "22.0W")
        #expect(snapshot.menuBarTitle == "80% · 10.0W")
    }

    @Test
    func conflictingDirectionsKeepKnownSystemPowerAndOneUnavailableSource() {
        let snapshot = makeTelemetrySnapshot(
            batteryVoltageV: 12,
            batteryCurrentA: 1,
            batteryPowerW: 12,
            adapterInputPowerW: 10,
            systemLoadW: 15
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(readings.fallbackReason == .conflictingDirection)
        #expect(!readings.hasBalancedFlow)
        #expect(readings.candidateSystemPower == nil)
        #expect(readings.systemPower == DisplayedPowerMeasurement(watts: 15, isApproximate: false))
        #expect(model.state == .unknown)
        #expect(model.connectionStyle == .hidden)
        #expect(model.routes.count == 1)
        #expect(model.routes.first?.source.value == L10n.text("common.none"))
        #expect(model.routes.first?.target.value == "15.0W")
        #expect(snapshot.hasConflictingBatteryPowerMeasurements)
        #expect(!snapshot.hasCorroboratedPowerDeliveryShortfall)
    }

    @Test
    func batteryOnlyDisplayUsesSystemPowerEvenWhenTheBatteryReadingIsFarHigher() {
        let snapshot = makeTelemetrySnapshot(
            powerSource: .battery,
            externalConnected: false,
            batteryVoltageV: 12,
            batteryCurrentA: -2,
            batteryPowerW: 24,
            adapterInputPowerW: 0,
            systemLoadW: 6
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(readings.candidateSystemPowerW == 24)
        #expect(readings.discrepancyW == 18)
        #expect(readings.hasBalancedFlow)
        #expect(readings.fallbackReason == nil)
        #expect(readings.systemPowerSource == .measured)
        #expect(model.state == .discharging)
        #expect(model.connectionStyle == .solid)
        #expect(model.routes.first?.source.value == "6.0W")
        #expect(model.routes.first?.target.value == "6.0W")
        #expect(snapshot.batteryPowerW == 24)
        #expect(snapshot.menuBarTitle == "80% · 6.0W")
    }

    @Test
    func displayedAssistDoesNotReplaceRawDiagnosticEvidence() {
        let snapshot = makeTelemetrySnapshot(
            batteryVoltageV: 12,
            batteryCurrentA: -5.741 / 12,
            batteryPowerW: 5.741,
            batteryPowerSource: .directTelemetry,
            adapterInputPowerW: 22.277,
            systemLoadW: 35.005
        )
        let readings = PowerFlowReadings(snapshot: snapshot)

        #expect(readings.hasBalancedFlow)
        #expect(readings.systemPowerSource == .measured)
        #expect(readings.inputPower?.formatted == "29.3W")
        #expect(readings.batteryPower?.formatted == "5.7W")
        #expect(!snapshot.hasConflictingBatteryPowerMeasurements)
        #expect(!snapshot.hasConflictingDischargePowerBalance)
        #expect(snapshot.hasCorroboratedPowerDeliveryShortfall)
        #expect(snapshot.diagnostics.contains { $0.kind == .powerDeliveryShortfall })
        #expect(snapshot.adapterInputPowerW == 22.277)
        #expect(snapshot.systemLoadW == 35.005)
        #expect(snapshot.batteryPowerW == 5.741)
    }

    @Test
    func assistTooltipDistinguishesDisplayedAndOriginalValuesAcrossEndpointsAndMenu() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: 0,
            batteryPowerW: 0.4,
            batteryPowerSource: .directTelemetry,
            adapterInputPowerW: 16.9,
            systemLoadW: 19.5
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)
        let tooltip = PowerFlowTooltip.text(snapshot: snapshot)
        let observedExpression = L10n.tr("ui.flow.tooltip.expression.assist", "16.9W", "0.4W")

        #expect(readings.systemPower?.isApproximate == false)
        #expect(readings.inputPower?.isApproximate == true)
        #expect(readings.batteryPower?.isApproximate == false)
        #expect(tooltip.contains(L10n.text("ui.flow.tooltip.anchor.measured")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.displayedSystem", "19.5W")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.displayAssist", "19.1W", "0.4W", "19.5W")))
        #expect(tooltip.contains(L10n.text("ui.flow.tooltip.inputFromAnchor")))
        #expect(!tooltip.contains(L10n.text("ui.flow.tooltip.smcTiming")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.observedBalance", observedExpression, "17.3W")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.observedBalanceDifference", "2.2W")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.rawInput", "16.9W")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.rawBattery", L10n.tr("format.batteryPower.discharging", "0.4W"))))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.rawSystem", "19.5W")))
        #expect(LivePowerPresentation(snapshot: snapshot, resolvedState: nil, diagnostics: [], isAwaitingSource: false).tooltip == tooltip)
        #expect(model.routes.allSatisfy { !$0.source.value.contains("≈") && !$0.target.value.contains("≈") })
        #expect(snapshot.menuBarTitle == "80% · 19.5W")

        let headline = "Current power source status"
        #expect(PowerFlowTooltip.menuBar(snapshot: snapshot, statusHeadline: headline) == "\(headline)\n\n\(tooltip)")
        #expect(PowerFlowTooltip.menuBar(snapshot: nil, statusHeadline: headline) == headline)
        #expect(PowerFlowTooltip.menuBar(snapshot: nil, statusHeadline: nil) == "PowerLens")
        #expect(PowerFlowTooltip.menuBar(snapshot: snapshot, statusHeadline: nil) == "PowerLens\n\n\(tooltip)")
    }

    @Test
    func tooltipRetainsOriginalPrecisionWhenTheDisplayedInputIsCalculated() {
        let snapshot = makeTelemetrySnapshot(
            batteryVoltageV: 12,
            batteryCurrentA: -6.393 / 12,
            batteryPowerW: 6.393,
            batteryPowerSource: .directTelemetry,
            adapterInputPowerW: 53.277,
            systemLoadW: 6.46
        )
        let tooltip = PowerFlowTooltip.text(snapshot: snapshot)
        let expression = L10n.tr("ui.flow.tooltip.expression.assist", "53.277W", "6.393W")

        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.displayedSystem", "6.5W")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.displayAssist", "0.1W", "6.4W", "6.5W")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.observedBalance", expression, "59.67W")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.rawInput", "53.277W")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.rawBattery", L10n.tr("format.batteryPower.discharging", "6.393W"))))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.rawSystem", "6.46W")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.observedBalanceDifference", "53.21W")))
        #expect(!tooltip.contains(L10n.tr("ui.flow.tooltip.displayedSystem", "59.7W")))
    }

    @Test
    func negativeOriginalBalanceIsComparisonInformationWhenASystemAnchorExists() {
        let snapshot = makeTelemetrySnapshot(
            isCharging: true,
            batteryVoltageV: 12,
            batteryCurrentA: 1,
            batteryPowerW: -12,
            adapterInputPowerW: 10,
            systemLoadW: 15
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let tooltip = PowerFlowTooltip.text(snapshot: snapshot)
        let expression = L10n.tr("ui.flow.tooltip.expression.charging", "10.0W", "12.0W")

        #expect(readings.fallbackReason == nil)
        #expect(readings.hasBalancedFlow)
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.displayCharging", "27.0W", "15.0W", "12.0W")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.observedBalance", expression, "-2.0W")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.observedBalanceDifference", "17.0W")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.displayedSystem", "15.0W")))
        #expect(!tooltip.contains(L10n.text("ui.flow.tooltip.reason.invalidBalance")))
    }

    @Test(arguments: [nil, 15.0] as [Double?])
    func missingRequiredMeasurementsDoNotInventAFormulaOrZero(rawSystemW: Double?) {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: nil,
            batteryPowerW: nil,
            adapterInputPowerW: nil,
            systemLoadW: rawSystemW
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)
        let tooltip = PowerFlowTooltip.text(snapshot: snapshot)
        let unavailable = L10n.text("common.none")

        #expect(!readings.hasBalancedFlow)
        #expect(readings.fallbackReason == .missingMeasurement)
        #expect(readings.systemPower?.watts == rawSystemW)
        #expect(model.state == .unknown)
        #expect(model.routes.count == 1)
        #expect(model.connectionStyle == .hidden)
        #expect(model.routes.first?.source.value == unavailable)
        #expect(tooltip.contains(L10n.text("ui.flow.tooltip.noCalculation")))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.rawInput", unavailable)))
        #expect(tooltip.contains(L10n.tr("ui.flow.tooltip.rawBattery", unavailable)))
        #expect(tooltip.contains(L10n.text(rawSystemW == nil ? "ui.flow.tooltip.anchor.unavailable" : "ui.flow.tooltip.anchor.measured")))
        #expect(!tooltip.contains(" = "))
        #expect(!tooltip.contains("0.0W"))
    }

    @Test(arguments: [-1.0, Double.nan, Double.infinity])
    func invalidAssistInputHidesTheRoute(inputW: Double) {
        let snapshot = makeTelemetrySnapshot(
            batteryVoltageV: 12,
            batteryCurrentA: -1,
            batteryPowerW: 12,
            adapterInputPowerW: inputW,
            systemLoadW: 20
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(readings.fallbackReason == .invalidBalance)
        #expect(!readings.hasBalancedFlow)
        #expect(readings.systemPower == DisplayedPowerMeasurement(watts: 20, isApproximate: false))
        #expect(model.state == .unknown)
        #expect(model.connectionStyle == .hidden)
        #expect(model.routes.count == 1)
        #expect(model.routes.first?.source.value == L10n.text("common.none"))
        #expect(model.routes.first?.target.value == "20.0W")
    }

    @Test(arguments: [Double.nan, Double.infinity])
    func nonfiniteBatteryPowerIsNotTreatedAsACalmOrConfirmedBatteryFlow(batteryW: Double) {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: 0,
            batteryPowerW: batteryW,
            adapterInputPowerW: 10,
            systemLoadW: 20
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(readings.fallbackReason == .invalidBalance)
        #expect(!readings.hasBalancedFlow)
        #expect(readings.systemPower == DisplayedPowerMeasurement(watts: 20, isApproximate: false))
        #expect(model.state == .unknown)
        #expect(model.connectionStyle == .hidden)
        #expect(model.routes.count == 1)
    }

    @Test(arguments: [10.0, -6.0])
    func batteryOnlyConflictingOrChargingEvidenceDoesNotReverseTheMeasuredDirection(batteryW: Double) {
        let snapshot = makeTelemetrySnapshot(
            powerSource: .battery,
            externalConnected: false,
            batteryVoltageV: 12,
            batteryCurrentA: 0.5,
            batteryPowerW: batteryW,
            adapterInputPowerW: 0,
            systemLoadW: 8
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(readings.fallbackReason == .conflictingDirection)
        #expect(!readings.hasBalancedFlow)
        #expect(readings.systemPower == DisplayedPowerMeasurement(watts: 8, isApproximate: false))
        #expect(model.state == .unknown)
        #expect(model.connectionStyle == .hidden)
        #expect(model.routes.count == 1)
        #expect(model.routes.first?.source.role == .battery)
        #expect(model.routes.first?.source.value == L10n.text("common.none"))
        #expect(model.routes.first?.target.value == "8.0W")
        #expect(snapshot.batteryPowerW == batteryW)
        #expect(snapshot.batteryCurrentA == 0.5)
    }
}
