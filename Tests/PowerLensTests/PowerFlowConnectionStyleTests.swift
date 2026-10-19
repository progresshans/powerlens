import Testing
@testable import PowerLens

struct PowerFlowConnectionStyleTests {
    @Test(arguments: [
        PowerFlowDiagramState.charging, .holding, .underpowered,
        .discharging, .directPower,
    ])
    func changingRawBalanceKeepsTheSystemAnchorAndSolidConnections(state: PowerFlowDiagramState) {
        let snapshots: [TelemetrySnapshot]
        switch state {
        case .charging:
            snapshots = [22.0, 32.0, 22.0].map { inputW in
                makeTelemetrySnapshot(
                    isCharging: true, batteryVoltageV: 12,
                    batteryCurrentA: 1, batteryPowerW: -12,
                    adapterInputPowerW: inputW, systemLoadW: 20
                )
            }
        case .holding:
            snapshots = [12.0, 20.0, 12.0].map { inputW in
                makeTelemetrySnapshot(
                    batteryCurrentA: 0, batteryPowerW: 0.1,
                    adapterInputPowerW: inputW, systemLoadW: 20
                )
            }
        case .underpowered:
            snapshots = [35.0, 19.6, 35.0].map { inputW in
                makeTelemetrySnapshot(
                    batteryCurrentA: 0, batteryPowerW: 0.4,
                    adapterInputPowerW: inputW, systemLoadW: 20
                )
            }
        case .discharging:
            snapshots = [6.0, 20.0, 6.0].map { batteryW in
                makeTelemetrySnapshot(
                    powerSource: .battery, externalConnected: false,
                    batteryCurrentA: -1, batteryPowerW: batteryW,
                    adapterInputPowerW: 0, systemLoadW: 20
                )
            }
        case .directPower:
            snapshots = [10.8, 20.0, 10.8].map { inputW in
                makeTelemetrySnapshot(
                    timeToEmptyMinutes: 60,
                    batteryCurrentA: 0, batteryPowerW: 0,
                    adapterInputPowerW: inputW, systemLoadW: 20
                )
            }
        case .unknown:
            Issue.record("This regression requires a known observed direction.")
            return
        }

        let readings = snapshots.map { PowerFlowReadings(snapshot: $0) }
        let models = snapshots.map { PowerFlowPresentationModel(snapshot: $0) }
        #expect(readings.allSatisfy { $0.fallbackReason == nil && $0.hasBalancedFlow })
        #expect(readings.allSatisfy { $0.systemPowerSource == .measured })
        #expect(models.map(\.state) == [state, state, state])
        #expect(models.map(\.connectionStyle) == [.solid, .solid, .solid])
        #expect(models.allSatisfy { $0.showsConnections })
        #expect(models.allSatisfy { $0.statusTitle == state.localizedTitle })
        #expect(models.allSatisfy { $0.routes.map(\.role) == models[0].routes.map(\.role) })
        #expect(snapshots.allSatisfy { $0.menuBarTitle == "80% · 20.0W" })
        for model in models {
            let systemRoutes = model.routes.filter { $0.target.role == .system }
            #expect(!systemRoutes.isEmpty)
            #expect(systemRoutes.allSatisfy { $0.target.value == "20.0W" })
        }
    }

    @Test
    func aNegativeObservedChargeBalanceCannotReplaceAKnownSystemAnchor() {
        let snapshots = [10.0, 27.0, 10.0].map { inputW in
            makeTelemetrySnapshot(
                isCharging: true, batteryVoltageV: 12,
                batteryCurrentA: 1, batteryPowerW: -12,
                adapterInputPowerW: inputW, systemLoadW: 15
            )
        }
        let readings = snapshots.map { PowerFlowReadings(snapshot: $0) }
        let models = snapshots.map { PowerFlowPresentationModel(snapshot: $0) }

        #expect(readings.map(\.candidateSystemPowerW) == [-2, 15, -2])
        #expect(readings.allSatisfy { $0.hasBalancedFlow && $0.fallbackReason == nil })
        #expect(models.map(\.state) == [.charging, .charging, .charging])
        #expect(models.map(\.connectionStyle) == [.solid, .solid, .solid])
        #expect(models.allSatisfy { $0.routes.map(\.role) == [.input, .charge] })
        #expect(models.allSatisfy { $0.routes.first?.source.value == "27.0W" })
        #expect(models.allSatisfy { $0.routes.first { $0.target.role == .charge }?.target.value == "12.0W" })
        #expect(snapshots.allSatisfy { $0.menuBarTitle == "80% · 15.0W" })
    }

    @Test
    func balancedPresentationDoesNotHideAGenuineDirectionConflictOrReversal() {
        let snapshots = [
            makeTelemetrySnapshot(
                batteryCurrentA: -0.5, batteryPowerW: 5,
                adapterInputPowerW: 20, systemLoadW: 6
            ),
            makeTelemetrySnapshot(
                batteryCurrentA: 0.5, batteryPowerW: 5,
                adapterInputPowerW: 20, systemLoadW: 6
            ),
            makeTelemetrySnapshot(
                isCharging: true, batteryCurrentA: 0.5, batteryPowerW: -5,
                adapterInputPowerW: 20, systemLoadW: 6
            ),
        ]
        let models = snapshots.map { PowerFlowPresentationModel(snapshot: $0) }

        #expect(models.map(\.state) == [.underpowered, .unknown, .charging])
        #expect(models.map(\.connectionStyle) == [.solid, .hidden, .solid])
        #expect(models.map(\.showsConnections) == [true, false, true])
        #expect(models[1].routes.count == 1)
        #expect(models[1].routes.first?.source.value == L10n.text("common.none"))
        #expect(snapshots.allSatisfy { $0.menuBarTitle == "80% · 6.0W" })
    }

    @Test
    func smcChargingSignOverridesAStaleDischargeCurrent() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: -0.1, batteryPowerW: -1,
            batteryPowerSource: .directTelemetry,
            adapterInputPowerW: 0.5, systemLoadW: 0.1,
            powerMeasurementSetSource: .smc
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(snapshot.batteryFlowEvidence == .conflicted)
        #expect(readings.smcBatteryDirection == .charging)
        #expect(readings.state == .charging)
        #expect(readings.fallbackReason == nil)
        #expect(readings.hasBalancedFlow)
        #expect(readings.systemPower == DisplayedPowerMeasurement(watts: 0.1, isApproximate: false))
        #expect(readings.inputPower?.formatted == "1.1W")
        #expect(readings.batteryPower?.formatted == "1.0W")
        #expect(model.state == .charging)
        #expect(model.connectionStyle == .solid)
        #expect(snapshot.menuBarTitle == "80% · 0.1W")
    }

    @Test(
        arguments: [nil, 0.0, 1.0, -1.0, Double.nan, Double.infinity, -Double.infinity] as [Double?],
        [true, false]
    )
    func nonfiniteBatteryDirectionReadingsAreHiddenButFiniteReadingsRemainUsable(value: Double?, usePower: Bool) {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: usePower ? 0 : value,
            batteryPowerW: usePower ? value : 0,
            adapterInputPowerW: 20, systemLoadW: 10
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)
        let isInvalid = value.map { !$0.isFinite } ?? false

        if isInvalid {
            #expect(readings.fallbackReason == .invalidBalance)
            #expect(!readings.hasBalancedFlow)
            #expect(readings.systemPower == DisplayedPowerMeasurement(watts: 10, isApproximate: false))
            #expect(model.state == .unknown)
            #expect(model.connectionStyle == .hidden)
        } else {
            #expect(readings.fallbackReason == nil)
            #expect(readings.hasBalancedFlow)
            #expect(model.state != .unknown)
            #expect(model.connectionStyle == .solid)
        }
    }

    @Test(arguments: [Double.infinity, -Double.infinity, Double.nan, -1.0])
    func invalidSmcSystemPowerFallsBackToTheObservedBalance(rawSystemW: Double) {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: -1, batteryPowerW: -12,
            batteryPowerSource: .directTelemetry,
            adapterInputPowerW: 20, systemLoadW: rawSystemW,
            powerMeasurementSetSource: .smc
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(snapshot.batteryFlowEvidence == .conflicted)
        #expect(readings.state == .charging)
        #expect(readings.fallbackReason == nil)
        #expect(readings.hasBalancedFlow)
        #expect(readings.systemPowerSource == .powerBalance)
        #expect(readings.systemPower == DisplayedPowerMeasurement(watts: 8, isApproximate: true))
        #expect(readings.inputPower?.formatted == "20.0W")
        #expect(readings.batteryPower?.formatted == "12.0W")
        #expect(model.state == .charging)
        #expect(model.connectionStyle == .solid)
        #expect(snapshot.menuBarTitle == "80% · 8.0W")
    }

    @Test
    func chargingObservationsWhileUnpluggedCannotBecomeADischargeRoute() {
        let snapshot = makeTelemetrySnapshot(
            powerSource: .battery, externalConnected: false,
            batteryCurrentA: 0.5, batteryPowerW: -6,
            adapterInputPowerW: 0, systemLoadW: 10
        )
        let readings = PowerFlowReadings(snapshot: snapshot)
        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(snapshot.batteryFlowEvidence == .charging)
        #expect(readings.fallbackReason == .conflictingDirection)
        #expect(!readings.hasBalancedFlow)
        #expect(model.state == .unknown)
        #expect(model.connectionStyle == .hidden)
        #expect(model.routes.map(\.role) == [.battery])
        #expect(model.routes.first?.source.value == L10n.text("common.none"))
        #expect(model.routes.first?.target.value == "10.0W")
    }
}
