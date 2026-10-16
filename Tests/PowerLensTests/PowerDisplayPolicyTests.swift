import Testing
@testable import PowerLens

struct PowerDisplayPolicyTests {
    @Test
    func batteryScreenshotUsesTheSystemAnchorWithoutChangingSensorReadings() {
        let snapshot = makeTelemetrySnapshot(
            powerSource: .battery,
            externalConnected: false,
            batteryVoltageV: 12.29,
            batteryCurrentA: -1.49,
            batteryPowerW: 15.2,
            batteryPowerSource: .directTelemetry,
            adapterInputPowerW: 0,
            systemLoadW: 13.5
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)
        #expect(model.routes.first?.source.value == "13.5W")
        #expect(model.routes.first?.target.value == "13.5W")
        #expect(snapshot.menuBarTitle == "80% · 13.5W")
        #expect(PowerFlowReadings(snapshot: snapshot).systemPowerSource == .measured)

        let details = Dictionary(uniqueKeysWithValues: TelemetryDetailRows.powerSnapshot(snapshot))
        #expect(details[L10n.text("ui.metric.systemLoad")] == "13.5W")
        #expect(details[L10n.text("ui.detail.batteryPower")] == Formatters.batteryPowerFlow(15.2))
        #expect(snapshot.systemLoadW == 13.5)
        #expect(snapshot.batteryPowerW == 15.2)
    }

    @Test(arguments: [true, false])
    func batteryFallbackNeverUsesDisconnectedAdapterZero(hasSystemReading: Bool) {
        let snapshot = makeTelemetrySnapshot(
            powerSource: .battery,
            externalConnected: false,
            batteryCurrentA: nil,
            batteryPowerW: nil,
            adapterInputPowerW: 0,
            systemLoadW: hasSystemReading ? 13.5 : nil
        )

        #expect(snapshot.primaryDisplayedPower?.watts == (hasSystemReading ? 13.5 : nil))
        #expect(snapshot.menuBarTitle == (hasSystemReading ? "80% · 13.5W" : "80%"))
        #expect(
            PowerFlowPresentationModel(snapshot: snapshot).routes.first?.source.value
                == (hasSystemReading ? "13.5W" : L10n.text("common.none"))
        )
        #expect(
            PowerFlowPresentationModel(snapshot: snapshot).routes.first?.target.value
                == (hasSystemReading ? "13.5W" : L10n.text("common.none"))
        )
    }

    @Test
    func measuredSystemAnchorTakesPriorityOverCurrentDerivedBatteryConsumption() {
        let snapshot = makeTelemetrySnapshot(
            powerSource: .battery,
            externalConnected: false,
            batteryVoltageV: 12,
            batteryCurrentA: -1.5,
            batteryPowerW: nil,
            adapterInputPowerW: 0,
            systemLoadW: 16
        )

        #expect(snapshot.primaryDisplayedPower == DisplayedPowerMeasurement(watts: 16, isApproximate: false))
        #expect(snapshot.menuBarTitle == "80% · 16.0W")
        #expect(PowerFlowPresentationModel(snapshot: snapshot).routes.first?.source.value == "16.0W")
        #expect(PowerFlowPresentationModel(snapshot: snapshot).routes.first?.target.value == "16.0W")
        #expect(snapshot.measuredBatteryDischargeW == 18)
        #expect(snapshot.batteryPowerW == nil)
        #expect(snapshot.systemLoadW == 16)
    }

    @Test(arguments: [nil, 0.0, 20.0] as [Double?])
    func calmInputUsesTheSystemAnchorWhileDetailsPreserveUnknownZeroAndMeasuredInput(adapterInputPowerW: Double?) {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: 0,
            batteryPowerW: 0,
            adapterInputPowerW: adapterInputPowerW,
            systemLoadW: 12
        )
        let model = PowerFlowPresentationModel(snapshot: snapshot)
        let originalInput = adapterInputPowerW.map(Formatters.power) ?? L10n.text("common.none")

        #expect(model.routes.first?.source.value == "12.0W")
        let expectedSystem = "12.0W"
        #expect(model.routes.first?.target.value == expectedSystem)
        #expect(snapshot.menuBarTitle == "80% · \(expectedSystem)")
        let details = Dictionary(uniqueKeysWithValues: TelemetryDetailRows.powerSnapshot(snapshot))
        #expect(details[L10n.text("ui.metric.powerIn")] == originalInput)
        #expect(snapshot.adapterInputPowerW == adapterInputPowerW)
        #expect(PowerFlowReadings(snapshot: snapshot).systemPowerSource == .measured)
    }

    @Test(arguments: [PowerFlowDiagramState.discharging, .charging, .underpowered, .holding, .directPower, .unknown])
    func everyFlowStateSharesItsSystemEndpointWithTheMenuBar(state: PowerFlowDiagramState) {
        let snapshot: TelemetrySnapshot
        switch state {
        case .discharging:
            snapshot = makeTelemetrySnapshot(powerSource: .battery, externalConnected: false, batteryCurrentA: -1, batteryPowerW: 12, systemLoadW: 10)
        case .charging:
            snapshot = makeTelemetrySnapshot(batteryCurrentA: 1, batteryPowerW: -12, adapterInputPowerW: 22, systemLoadW: 10)
        case .underpowered:
            snapshot = makeTelemetrySnapshot(batteryCurrentA: -1, batteryPowerW: 12, adapterInputPowerW: 10, systemLoadW: 22)
        case .holding:
            snapshot = makeTelemetrySnapshot(batteryCurrentA: 0, batteryPowerW: 0, adapterInputPowerW: 10, systemLoadW: 10)
        case .directPower:
            snapshot = makeTelemetrySnapshot(timeToEmptyMinutes: 60, batteryCurrentA: 0, batteryPowerW: 0, adapterInputPowerW: 10, systemLoadW: 10)
        case .unknown:
            snapshot = makeTelemetrySnapshot(batteryCurrentA: 1, batteryPowerW: 12, adapterInputPowerW: 10, systemLoadW: 10)
        }

        let model = PowerFlowPresentationModel(snapshot: snapshot)
        #expect(model.state == state)
        let systemRoutes = model.routes.filter { $0.target.role == .system }
        #expect(!systemRoutes.isEmpty)
        let systemValue = snapshot.primaryDisplayedPower?.formatted
        #expect(systemRoutes.allSatisfy { $0.target.value == (systemValue ?? L10n.text("common.none")) })
        #expect(snapshot.menuBarTitle == systemValue.map { "80% · \($0)" } ?? "80%")
        let expectedInput = state == .unknown
            ? L10n.text("common.none")
            : snapshot.adapterInputPowerW.map(Formatters.power) ?? L10n.text("common.none")
        #expect(model.routes.filter { $0.source.role == .input }.allSatisfy {
            $0.source.value == expectedInput
        })
    }

    @Test(arguments: [-12.0, 12.0, 0.0])
    func acConsumptionFallbackAccountsForBatteryDirection(batteryPowerW: Double) {
        let snapshot = makeTelemetrySnapshot(
            batteryVoltageV: 12,
            batteryCurrentA: -batteryPowerW / 12,
            batteryPowerW: batteryPowerW,
            adapterInputPowerW: 20,
            systemLoadW: nil
        )

        #expect(snapshot.primaryDisplayedPower == DisplayedPowerMeasurement(watts: 20 + batteryPowerW, isApproximate: true))
        #expect(snapshot.systemLoadW == nil)
        #expect(PowerFlowReadings(snapshot: snapshot).systemPowerSource == .powerBalance)
        let model = PowerFlowPresentationModel(snapshot: snapshot)
        #expect(model.routes.first?.target.value == snapshot.primaryDisplayedPower?.formatted)
    }

    @Test
    func unknownOrConflictingACBalanceDoesNotInventConsumptionOrWarningEvidence() {
        let snapshots = [
            makeTelemetrySnapshot(batteryCurrentA: nil, batteryPowerW: nil, adapterInputPowerW: 20, systemLoadW: nil),
            makeTelemetrySnapshot(batteryCurrentA: 1, batteryPowerW: 12, adapterInputPowerW: 20, systemLoadW: nil),
            makeTelemetrySnapshot(batteryCurrentA: 2, batteryPowerW: -24, adapterInputPowerW: 20, systemLoadW: nil),
        ]

        for snapshot in snapshots {
            #expect(snapshot.primaryDisplayedPower == nil)
            #expect(snapshot.menuBarTitle == "80%")
            let readings = PowerFlowReadings(snapshot: snapshot)
            let model = PowerFlowPresentationModel(snapshot: snapshot)
            #expect(!readings.hasBalancedFlow)
            #expect(readings.systemPowerSource == .unavailable)
            #expect(model.state == .unknown)
            #expect(model.routes.count == 1)
            #expect(model.routes.first?.source.value == L10n.text("common.none"))
            #expect(model.routes.first?.target.value == L10n.text("common.none"))
            #expect(!snapshot.hasCorroboratedPowerDeliveryShortfall)
        }
    }
}
