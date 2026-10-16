import Testing
@testable import PowerLens

struct PowerFlowBalanceTests {
    struct AssistExample: Sendable {
        let inputW: Double
        let batteryW: Double
        let rawSystemW: Double
        let shownInput: String
        let shownBattery: String
        let shownSystem: String
        var adjustment: PowerFlowInputAdjustment?
    }

    @Test
    func holdingAnchorsBothVisibleEndpointsToTheSystemSensor() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: 0, batteryPowerW: 0.1,
            batteryPowerSource: .directTelemetry,
            adapterInputPowerW: 18.2, systemLoadW: 17.4
        )
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .holding)
        #expect(model.connectionStyle == .solid)
        #expect(model.routes.count == 1)
        #expect(model.routes.first?.source.value == "17.4W")
        #expect(model.routes.first?.target.value == "17.4W")
        #expect(snapshot.primaryDisplayedPower?.formatted == "17.4W")
        #expect(snapshot.menuBarTitle == "80% · 17.4W")

        let details = Dictionary(uniqueKeysWithValues: TelemetryDetailRows.powerSnapshot(snapshot))
        #expect(details[L10n.text("ui.metric.systemLoad")] == "17.4W")
        #expect(details[L10n.text("ui.detail.batteryPower")] == Formatters.batteryPowerFlow(0.1))
        #expect(snapshot.adapterInputPowerW == 18.2)
        #expect(snapshot.systemLoadW == 17.4)
        #expect(snapshot.batteryPowerW == 0.1)
    }

    @Test(arguments: [
        AssistExample(inputW: 16.9, batteryW: 0.4, rawSystemW: 19.5,
                      shownInput: "19.1W", shownBattery: "0.4W", shownSystem: "19.5W"),
        AssistExample(inputW: 18.8, batteryW: 1.2, rawSystemW: 19.3,
                      shownInput: "18.1W", shownBattery: "1.2W", shownSystem: "19.3W"),
        AssistExample(inputW: 16.94, batteryW: 0.44, rawSystemW: 17.3,
                      shownInput: "16.9W", shownBattery: "0.4W", shownSystem: "17.3W"),
        // Just after a charger connects, the SMC system sum still pairs the
        // previous ~0 W input with the battery discharge.
        AssistExample(inputW: 53.277, batteryW: 6.393, rawSystemW: 6.46,
                      shownInput: "0.1W", shownBattery: "6.4W", shownSystem: "6.5W"),
        AssistExample(inputW: 22.277, batteryW: 5.741, rawSystemW: 35.005,
                      shownInput: "29.3W", shownBattery: "5.7W", shownSystem: "35.0W"),
        AssistExample(inputW: 1, batteryW: 1, rawSystemW: 0.1,
                      shownInput: "0.0W", shownBattery: "0.1W", shownSystem: "0.1W",
                      adjustment: .raisedToZero),
        AssistExample(inputW: 1, batteryW: 9, rawSystemW: 2,
                      shownInput: "0.0W", shownBattery: "2.0W", shownSystem: "2.0W",
                      adjustment: .raisedToZero),
    ])
    func batteryAssistSubtractsTheMeasuredDischargeFromTheSystemAnchor(example: AssistExample) throws {
        let snapshot = makeTelemetrySnapshot(
            batteryVoltageV: 12, batteryCurrentA: 0,
            batteryPowerW: example.batteryW, batteryPowerSource: .directTelemetry,
            adapterInputPowerW: example.inputW, systemLoadW: example.rawSystemW
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .underpowered)
        #expect(model.connectionStyle == .solid)
        #expect(model.routes.map(\.role) == [.input, .battery])
        #expect(model.routes.first { $0.source.role == .input }?.source.value == example.shownInput)
        #expect(model.routes.first { $0.source.role == .battery }?.source.value == example.shownBattery)
        #expect(model.routes.allSatisfy { $0.target.value == example.shownSystem })
        #expect(snapshot.primaryDisplayedPower?.formatted == example.shownSystem)
        #expect(snapshot.primaryDisplayedPower?.isApproximate == false)
        #expect(snapshot.menuBarTitle == "80% · \(example.shownSystem)")
        let input = try #require(readings.inputPower)
        let battery = try #require(readings.batteryPower)
        let system = try #require(readings.systemPower)
        #expect(Int((input.watts * 10).rounded()) + Int((battery.watts * 10).rounded())
                == Int((system.watts * 10).rounded()))
        #expect(readings.inputAdjustment == example.adjustment)
        // The measured battery value is shown as-is unless an adjustment was needed.
        #expect(battery.isApproximate == (example.adjustment != nil))

        let details = Dictionary(uniqueKeysWithValues: TelemetryDetailRows.powerSnapshot(snapshot))
        #expect(details[L10n.text("ui.metric.systemLoad")] == Formatters.power(example.rawSystemW))
        #expect(snapshot.adapterInputPowerW == example.inputW)
        #expect(snapshot.batteryPowerW == example.batteryW)
        #expect(snapshot.systemLoadW == example.rawSystemW)
    }

    struct ChargeExample: Sendable {
        let inputW: Double
        let chargeW: Double
        let rawSystemW: Double
        let shownInput: String
        let shownCharge: String
        let shownSystem: String
    }

    @Test(arguments: [
        ChargeExample(inputW: 22, chargeW: 12, rawSystemW: 9.5,
                      shownInput: "21.5W", shownCharge: "12.0W", shownSystem: "9.5W"),
        ChargeExample(inputW: 22.04, chargeW: 12.06, rawSystemW: 9.5,
                      shownInput: "21.6W", shownCharge: "12.1W", shownSystem: "9.5W"),
        ChargeExample(inputW: 12, chargeW: 12, rawSystemW: 0,
                      shownInput: "12.0W", shownCharge: "12.0W", shownSystem: "0.0W"),
        ChargeExample(inputW: 10, chargeW: 12, rawSystemW: 15,
                      shownInput: "27.0W", shownCharge: "12.0W", shownSystem: "15.0W"),
    ])
    func chargingAddsTheObservedChargeToTheSystemAnchor(example: ChargeExample) throws {
        let snapshot = makeTelemetrySnapshot(
            isCharging: true, batteryVoltageV: 12,
            batteryCurrentA: example.chargeW / 12, batteryPowerW: -example.chargeW,
            batteryPowerSource: .directTelemetry,
            adapterInputPowerW: example.inputW, systemLoadW: example.rawSystemW
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .charging)
        #expect(model.connectionStyle == .solid)
        #expect(model.routes.map(\.role) == [.input, .charge])
        #expect(model.routes.allSatisfy { $0.source.value == example.shownInput })
        #expect(model.routes.first { $0.target.role == .charge }?.target.value == example.shownCharge)
        #expect(model.routes.first { $0.target.role == .system }?.target.value == example.shownSystem)
        #expect(snapshot.menuBarTitle == "80% · \(example.shownSystem)")
        let input = try #require(readings.inputPower)
        let charge = try #require(readings.batteryPower)
        let system = try #require(readings.systemPower)
        #expect(Int((input.watts * 10).rounded())
                == Int((system.watts * 10).rounded()) + Int((charge.watts * 10).rounded()))
        #expect(snapshot.adapterInputPowerW == example.inputW)
        #expect(snapshot.batteryPowerW == -example.chargeW)
        #expect(snapshot.systemLoadW == example.rawSystemW)
    }

    @Test(arguments: [22.0, 40.0])
    func displayBalanceDoesNotTurnConflictingRawReadingsIntoCorroboratedDiagnostics(rawSystemW: Double) {
        let snapshot = makeTelemetrySnapshot(
            batteryVoltageV: 12, batteryCurrentA: -1, batteryPowerW: 12,
            batteryPowerSource: .directTelemetry,
            adapterInputPowerW: 10, systemLoadW: rawSystemW
        )
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.routes.allSatisfy { $0.target.value == Formatters.power(rawSystemW) })
        #expect(model.state == .underpowered)
        #expect(model.connectionStyle == .solid)
        #expect(!snapshot.hasConflictingBatteryPowerMeasurements)
        #expect(snapshot.hasConflictingDischargePowerBalance == (rawSystemW == 40))
        #expect(snapshot.hasCorroboratedPowerDeliveryShortfall == (rawSystemW == 22))
        #expect(snapshot.diagnostics.contains { $0.kind == .powerDeliveryShortfall } == (rawSystemW == 22))
        #expect(snapshot.estimatedPowerDeficitW == rawSystemW - 10)
        #expect(snapshot.withChargingPolicyStatus(nil).systemLoadW == rawSystemW)
    }

    @Test
    func missingAssistInputIsCalculatedFromTheSystemAnchorLikeCharging() {
        let snapshot = makeTelemetrySnapshot(
            batteryVoltageV: 12, batteryCurrentA: -1, batteryPowerW: 12,
            adapterInputPowerW: nil, systemLoadW: 15
        )
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .underpowered)
        #expect(model.connectionStyle == .solid)
        #expect(model.routes.map(\.role) == [.input, .battery])
        #expect(model.routes.first { $0.source.role == .input }?.source.value == "3.0W")
        #expect(model.routes.first { $0.source.role == .battery }?.source.value == "12.0W")
        #expect(model.routes.allSatisfy { $0.target.value == "15.0W" })
        #expect(snapshot.primaryDisplayedPower == DisplayedPowerMeasurement(watts: 15, isApproximate: false))
        let details = Dictionary(uniqueKeysWithValues: TelemetryDetailRows.powerSnapshot(snapshot))
        #expect(details[L10n.text("ui.metric.powerIn")] == L10n.text("common.none"))
    }

    @Test
    func knownBatteryDirectionWithoutWattageDoesNotTreatTheMissingBranchAsZero() {
        let snapshot = makeTelemetrySnapshot(
            batteryVoltageV: nil, batteryCurrentA: -1, batteryPowerW: nil,
            adapterInputPowerW: 10, systemLoadW: 15
        )
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .unknown)
        #expect(model.connectionStyle == .hidden)
        #expect(model.routes.map(\.role) == [.input])
        #expect(model.routes.first?.source.value == L10n.text("common.none"))
        #expect(model.routes.first?.target.value == "15.0W")
        #expect(snapshot.menuBarTitle == "80% · 15.0W")
    }

    @Test(arguments: [nil, 9.0] as [Double?])
    func unobservedDirectionDoesNotCreateABalancedRoute(rawSystemW: Double?) {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: nil, batteryPowerW: nil,
            adapterInputPowerW: 10, systemLoadW: rawSystemW
        )
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .unknown)
        #expect(model.connectionStyle == .hidden)
        #expect(model.routes.count == 1)
        #expect(model.routes.first?.source.value == L10n.text("common.none"))
        #expect(model.routes.first?.target.value == (rawSystemW.map(Formatters.power) ?? L10n.text("common.none")))
        #expect(snapshot.primaryDisplayedPower?.watts == rawSystemW)
        #expect(snapshot.systemLoadW == rawSystemW)
    }

    @Test(arguments: [nil, 15.0] as [Double?])
    func conflictingBatteryDirectionsNeverCreateABalancedRoute(rawSystemW: Double?) {
        let snapshot = makeTelemetrySnapshot(
            batteryVoltageV: 12, batteryCurrentA: 1, batteryPowerW: 12,
            adapterInputPowerW: 10, systemLoadW: rawSystemW
        )
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(snapshot.hasConflictingBatteryPowerMeasurements)
        #expect(model.state == .unknown)
        #expect(model.connectionStyle == .hidden)
        #expect(model.routes.count == 1)
        #expect(model.routes.first?.source.value == L10n.text("common.none"))
        #expect(model.routes.first?.target.value == (rawSystemW.map(Formatters.power) ?? L10n.text("common.none")))
        #expect(snapshot.primaryDisplayedPower?.watts == rawSystemW)
    }

    @Test
    func negativeChargeBalanceWithoutASystemAnchorRemainsUnavailable() {
        let snapshot = makeTelemetrySnapshot(
            isCharging: true, batteryVoltageV: 12,
            batteryCurrentA: 1, batteryPowerW: -12,
            adapterInputPowerW: 10, systemLoadW: nil
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(readings.candidateSystemPowerW == -2)
        #expect(readings.fallbackReason == .invalidBalance)
        #expect(model.state == .unknown)
        #expect(model.connectionStyle == .hidden)
        #expect(model.routes.count == 1)
        #expect(model.routes.first?.source.value == L10n.text("common.none"))
        #expect(model.routes.first?.target.value == L10n.text("common.none"))
        #expect(snapshot.primaryDisplayedPower == nil)
    }
}
