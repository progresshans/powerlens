import Testing
@testable import PowerLens

struct ChargingPolicyAwarenessTests {
    @Test
    func arbitraryManualLimitExplainsReductionWithoutChangingPhysicalFlow() {
        let physicalSnapshot = managedDischargeSnapshot(
            batteryLevel: 92,
            policy: nil
        )
        let managedSnapshot = managedDischargeSnapshot(
            batteryLevel: 92,
            policy: .manualLimit(targetPercent: 87)
        )

        #expect(physicalSnapshot.externalPowerState == .connected)
        #expect(managedSnapshot.externalPowerState == .connected)
        #expect(
            managedSnapshot.managedChargingState
                == .reducingToLimit(targetPercent: 87)
        )
        #expect(
            managedSnapshot.statusHeadline
                == L10n.tr(
                    "status.manualLimit.reducing",
                    Formatters.percent(87)
                )
        )
        #expect(
            managedSnapshot.statusSubheadline
                == L10n.text("status.subheadline.manualLimit.reducing")
        )
        #expect(managedSnapshot.shouldSuppressPowerDeliveryWarnings)

        let physicalFlow = PowerFlowPresentationModel(
            snapshot: physicalSnapshot
        )
        let managedFlow = PowerFlowPresentationModel(
            snapshot: managedSnapshot
        )

        #expect(managedFlow.state == physicalFlow.state)
        #expect(managedFlow.routes == physicalFlow.routes)
        #expect(managedFlow.state == .underpowered)
        #expect(managedFlow.routes.map(\.role) == [.input, .battery])
        #expect(
            managedFlow.statusTitle
                == L10n.tr(
                    "ui.flow.manualLimit.reducing",
                    Formatters.percent(87)
                )
        )
    }

    @Test
    func arbitraryManualLimitIsUsedWhileCharging() {
        let snapshot = makeTelemetrySnapshot(
            batteryLevel: 72,
            isCharging: true,
            timeToFullMinutes: 35,
            batteryCurrentA: 1.4,
            batteryPowerW: -20,
            adapterInputPowerW: 30,
            systemLoadW: 10,
            chargingPolicyStatus: .manualLimit(targetPercent: 93)
        )

        #expect(
            snapshot.managedChargingState
                == .chargingToLimit(targetPercent: 93)
        )
        #expect(
            snapshot.statusHeadline
                == L10n.tr(
                    "status.manualLimit.charging",
                    Formatters.percent(93)
                )
        )
        #expect(!snapshot.shouldSuppressPowerDeliveryWarnings)

        let flow = PowerFlowPresentationModel(snapshot: snapshot)
        #expect(flow.state == .charging)
        #expect(flow.routes.map(\.role) == [.input, .charge])
        #expect(
            flow.statusTitle
                == L10n.tr(
                    "ui.flow.manualLimit.charging",
                    Formatters.percent(93)
                )
        )
    }

    @Test
    func manualLimitChargingAllowsOnePercentUpperTelemetryTolerance() {
        let snapshot = makeTelemetrySnapshot(
            batteryLevel: 88,
            isCharging: true,
            timeToFullMinutes: 15,
            batteryCurrentA: 0.8,
            batteryPowerW: -9,
            adapterInputPowerW: 19,
            systemLoadW: 10,
            chargingPolicyStatus: .manualLimit(targetPercent: 87)
        )

        #expect(
            snapshot.managedChargingState
                == .chargingToLimit(targetPercent: 87)
        )
    }

    @Test
    func manualLimitHoldUsesTheSelectedTarget() {
        let snapshot = makeTelemetrySnapshot(
            batteryLevel: 85,
            batteryCurrentA: 0,
            batteryPowerW: 0,
            adapterInputPowerW: 11,
            systemLoadW: 11,
            chargingPolicyStatus: .manualLimit(targetPercent: 85)
        )

        #expect(
            snapshot.managedChargingState
                == .holdingAtLimit(targetPercent: 85)
        )
        #expect(
            snapshot.statusHeadline
                == L10n.tr(
                    "status.manualLimit.holding",
                    Formatters.percent(85)
                )
        )
        #expect(snapshot.shouldSuppressPowerDeliveryWarnings)

        let flow = PowerFlowPresentationModel(snapshot: snapshot)
        #expect(flow.state == .holding)
        #expect(flow.routes.map(\.role) == [.input])
        #expect(
            flow.statusTitle
                == L10n.tr(
                    "ui.flow.manualLimit.holding",
                    Formatters.percent(85)
                )
        )
    }

    @Test
    func compatibleTelemetryCanStillIdentifyManualLimitHold() {
        let snapshot = makeTelemetrySnapshot(
            batteryLevel: 85,
            batteryCurrentA: nil,
            batteryPowerW: nil,
            adapterInputPowerW: nil,
            systemLoadW: nil,
            chargingPolicyStatus: .manualLimit(targetPercent: 85)
        )

        #expect(snapshot.externalPowerState == .connected)
        #expect(
            snapshot.managedChargingState
                == .holdingAtLimit(targetPercent: 85)
        )
        #expect(snapshot.shouldSuppressPowerDeliveryWarnings)
        #expect(
            snapshot.statusHeadline
                == L10n.tr(
                    "status.manualLimit.holding",
                    Formatters.percent(85)
                )
        )

        let flow = PowerFlowPresentationModel(snapshot: snapshot)
        #expect(flow.state == .directPower)
        #expect(flow.routes.map(\.role) == [.input])
        #expect(
            flow.statusTitle
                == L10n.tr(
                    "ui.flow.manualLimit.holding",
                    Formatters.percent(85)
                )
        )
    }

    @Test
    func compatibleHoldFallbackRejectsConflictingEvidence() {
        let withDischargeEstimate = makeTelemetrySnapshot(
            batteryLevel: 85,
            timeToEmptyMinutes: 90,
            batteryCurrentA: nil,
            batteryPowerW: nil,
            adapterInputPowerW: nil,
            systemLoadW: nil,
            chargingPolicyStatus: .manualLimit(targetPercent: 85)
        )
        let withMeasuredBatteryFlow = makeTelemetrySnapshot(
            batteryLevel: 85,
            batteryCurrentA: nil,
            batteryPowerW: 5,
            adapterInputPowerW: nil,
            systemLoadW: nil,
            chargingPolicyStatus: .manualLimit(targetPercent: 85)
        )
        let withClearPowerDeficit = makeTelemetrySnapshot(
            batteryLevel: 85,
            batteryCurrentA: nil,
            batteryPowerW: nil,
            adapterInputPowerW: 10,
            systemLoadW: 16,
            chargingPolicyStatus: .manualLimit(targetPercent: 85)
        )

        for snapshot in [
            withDischargeEstimate,
            withMeasuredBatteryFlow,
            withClearPowerDeficit,
        ] {
            #expect(
                snapshot.managedChargingState
                    == .limitConfigured(targetPercent: 85)
            )
        }
    }

    @Test
    func manualLimitHoldUsesFivePercentLowerAndOnePercentUpperRange() {
        let lowerBoundary = calmSnapshot(
            batteryLevel: 80,
            targetPercent: 85
        )
        let upperBoundary = calmSnapshot(
            batteryLevel: 86,
            targetPercent: 85
        )
        let belowRange = calmSnapshot(
            batteryLevel: 79,
            targetPercent: 85
        )
        let aboveRange = calmSnapshot(
            batteryLevel: 87,
            targetPercent: 85
        )

        #expect(
            lowerBoundary.managedChargingState
                == .holdingAtLimit(targetPercent: 85)
        )
        #expect(
            upperBoundary.managedChargingState
                == .holdingAtLimit(targetPercent: 85)
        )
        #expect(
            belowRange.managedChargingState
                == .limitConfigured(targetPercent: 85)
        )
        #expect(
            aboveRange.managedChargingState
                == .limitConfigured(targetPercent: 85)
        )
    }

    @Test
    func hundredPercentLimitNeverClaimsReduction() {
        let snapshot = managedDischargeSnapshot(
            batteryLevel: 95,
            policy: .manualLimit(targetPercent: 100)
        )

        #expect(
            snapshot.managedChargingState
                == .limitConfigured(targetPercent: 100)
        )
        #expect(
            snapshot.statusHeadline
                == L10n.text("status.adapterBatteryAssist")
        )
        #expect(!snapshot.shouldSuppressPowerDeliveryWarnings)
        #expect(
            snapshot.managedChargingDiagnosticTitle
                == L10n.tr(
                    "status.manualLimit.active",
                    Formatters.percent(100)
                )
        )
    }

    @Test
    func dischargeBelowManualLimitRemainsAPhysicalPowerCondition() {
        let snapshot = managedDischargeSnapshot(
            batteryLevel: 70,
            policy: .manualLimit(targetPercent: 87)
        )

        #expect(
            snapshot.managedChargingState
                == .limitConfigured(targetPercent: 87)
        )
        #expect(
            snapshot.statusHeadline
                == L10n.text("status.adapterBatteryAssist")
        )
        #expect(!snapshot.shouldSuppressPowerDeliveryWarnings)
        #expect(
            snapshot.managedChargingDiagnosticTitle
                == L10n.tr(
                    "status.manualLimit.active",
                    Formatters.percent(87)
                )
        )
        #expect(
            PowerFlowPresentationModel(snapshot: snapshot).statusTitle
                == L10n.text("ui.flow.batteryAssist")
        )
    }

    @Test
    func chargingAboveManualLimitIsNotAttributedToTheLimit() {
        let snapshot = makeTelemetrySnapshot(
            batteryLevel: 90,
            isCharging: true,
            timeToFullMinutes: 20,
            batteryCurrentA: 1,
            batteryPowerW: -12,
            adapterInputPowerW: 22,
            systemLoadW: 10,
            chargingPolicyStatus: .manualLimit(targetPercent: 80)
        )

        #expect(
            snapshot.managedChargingState
                == .limitConfigured(targetPercent: 80)
        )
        #expect(
            snapshot.statusHeadline
                == L10n.text("status.chargingFromExternalPower")
        )
        #expect(
            snapshot.statusSubheadline
                != L10n.text("status.subheadline.manualLimit.charging")
        )
        #expect(
            PowerFlowPresentationModel(snapshot: snapshot).statusTitle
                == L10n.text("ui.flow.charging")
        )
    }

    @Test
    func saturatedAdapterWarningCanCoexistWithManualLimit() {
        let snapshot = makeTelemetrySnapshot(
            batteryLevel: 90,
            batteryCurrentA: -1.6,
            batteryPowerW: 20,
            adapterInputPowerW: 20,
            systemLoadW: 40,
            adapterMaxPowerW: 20,
            chargingPolicyStatus: .manualLimit(targetPercent: 80)
        )

        #expect(snapshot.hasClearAdapterCapacityShortfall)
        #expect(
            snapshot.managedChargingState
                == .limitConfigured(targetPercent: 80)
        )
        #expect(!snapshot.shouldSuppressPowerDeliveryWarnings)
        #expect(
            snapshot.statusHeadline
                == L10n.text("status.adapterBatteryAssist")
        )
        #expect(
            PowerFlowPresentationModel(snapshot: snapshot).statusTitle
                == L10n.text("ui.flow.batteryAssist")
        )
    }

    @Test
    func negotiatedLowSignalsDoNotOverrideManualLimitReduction() {
        let snapshot = makeTelemetrySnapshot(
            batteryLevel: 90,
            batteryCurrentA: -1.6,
            batteryPowerW: 10,
            adapterInputPowerW: 20,
            systemLoadW: 30,
            adapterMaxPowerW: 97,
            chargingPolicyStatus: .manualLimit(targetPercent: 80)
        )

        #expect(snapshot.hasNegotiatedLowCondition)
        #expect(!snapshot.hasClearAdapterCapacityShortfall)
        #expect(
            snapshot.managedChargingState
                == .reducingToLimit(targetPercent: 80)
        )
        #expect(snapshot.shouldSuppressPowerDeliveryWarnings)
        #expect(
            snapshot.statusHeadline
                == L10n.tr(
                    "status.manualLimit.reducing",
                    Formatters.percent(80)
                )
        )
    }

    @Test
    func disconnectedPowerTakesPriorityOverStalePolicy() {
        let snapshot = makeTelemetrySnapshot(
            batteryLevel: 70,
            powerSource: .battery,
            externalConnected: false,
            timeToEmptyMinutes: 180,
            batteryCurrentA: -0.8,
            batteryPowerW: 9,
            adapterInputPowerW: 0,
            systemLoadW: 9,
            adapterMaxPowerW: nil,
            chargingPolicyStatus: .manualLimit(targetPercent: 87)
        )

        #expect(snapshot.managedChargingState == nil)
        #expect(snapshot.externalPowerState == .onBattery)
        #expect(
            snapshot.statusHeadline
                == L10n.text("status.runningOnBattery")
        )

        let flow = PowerFlowPresentationModel(snapshot: snapshot)
        #expect(flow.state == .discharging)
        #expect(flow.routes.map(\.role) == [.battery])
        #expect(flow.statusTitle == L10n.text("ui.flow.batteryOnly"))
    }

    @Test
    func optimizedChargingOverridesCopyOnlyWhilePhysicallyCharging() {
        let snapshot = makeTelemetrySnapshot(
            batteryLevel: 76,
            isCharging: true,
            timeToFullMinutes: 40,
            batteryCurrentA: 1,
            batteryPowerW: -12,
            adapterInputPowerW: 22,
            systemLoadW: 10,
            chargingPolicyStatus: .optimizedCharging
        )

        #expect(snapshot.managedChargingState == .optimizedCharging)
        #expect(!snapshot.shouldSuppressPowerDeliveryWarnings)
        #expect(
            snapshot.statusHeadline
                == L10n.text("status.optimizedCharging.active")
        )
        #expect(
            PowerFlowPresentationModel(snapshot: snapshot).statusTitle
                == L10n.text("ui.flow.optimizedCharging.active")
        )
    }

    @Test
    func optimizedChargingHoldExplainsCalmBattery() {
        let snapshot = makeTelemetrySnapshot(
            batteryLevel: 80,
            batteryCurrentA: 0,
            batteryPowerW: 0,
            adapterInputPowerW: 11,
            systemLoadW: 11,
            chargingPolicyStatus: .optimizedCharging
        )

        #expect(snapshot.managedChargingState == .optimizedHold)
        #expect(snapshot.shouldSuppressPowerDeliveryWarnings)
        #expect(
            snapshot.statusHeadline
                == L10n.text("status.optimizedCharging.holding")
        )

        let flow = PowerFlowPresentationModel(snapshot: snapshot)
        #expect(flow.state == .holding)
        #expect(flow.routes.map(\.role) == [.input])
        #expect(
            flow.statusTitle
                == L10n.text("ui.flow.optimizedCharging.holding")
        )
    }

    @Test
    func optimizedPolicyDoesNotExplainActiveBatteryDischarge() {
        let snapshot = managedDischargeSnapshot(
            batteryLevel: 76,
            policy: .optimizedCharging
        )

        #expect(snapshot.managedChargingState == .optimizedActive)
        #expect(!snapshot.shouldSuppressPowerDeliveryWarnings)
        #expect(
            snapshot.statusHeadline
                == L10n.text("status.adapterBatteryAssist")
        )
        #expect(
            snapshot.managedChargingDiagnosticTitle
                == L10n.text("status.optimizedCharging.active")
        )
        #expect(
            PowerFlowPresentationModel(snapshot: snapshot).statusTitle
                == L10n.text("ui.flow.batteryAssist")
        )
    }

    @Test
    func invalidRuntimeManualLimitsAreIgnored() {
        let zero = calmSnapshot(batteryLevel: 80, targetPercent: 0)
        let overHundred = calmSnapshot(
            batteryLevel: 80,
            targetPercent: 101
        )

        #expect(zero.managedChargingState == nil)
        #expect(overHundred.managedChargingState == nil)
    }

    private func managedDischargeSnapshot(
        batteryLevel: Double,
        policy: ObservedChargingPolicyStatus?
    ) -> TelemetrySnapshot {
        makeTelemetrySnapshot(
            batteryLevel: batteryLevel,
            timeToEmptyMinutes: 120,
            batteryCurrentA: -1.2,
            batteryPowerW: 14.8,
            adapterInputPowerW: 0.2,
            systemLoadW: 15,
            chargingPolicyStatus: policy
        )
    }

    private func calmSnapshot(
        batteryLevel: Double,
        targetPercent: Int
    ) -> TelemetrySnapshot {
        makeTelemetrySnapshot(
            batteryLevel: batteryLevel,
            batteryCurrentA: 0,
            batteryPowerW: 0,
            adapterInputPowerW: 11,
            systemLoadW: 11,
            chargingPolicyStatus: .manualLimit(
                targetPercent: targetPercent
            )
        )
    }
}
