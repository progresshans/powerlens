import Foundation
import Testing
@testable import PowerLens

struct PowerStateTrackerTests {
    private let start = Date(timeIntervalSince1970: 2_000_000_000)
    private let configuration = PowerStateHysteresisConfiguration()

    @Test
    func measuredDischargeOverridesAStaleChargingFlag() {
        let snapshot = assistSnapshot(
            at: 0,
            isCharging: true,
            batteryLevel: 80,
            policy: .manualLimit(targetPercent: 80)
        )

        #expect(snapshot.batteryFlowEvidence == .discharging)
        #expect(!snapshot.isBatteryChargingForDisplay)
        #expect(snapshot.externalPowerState != .charging)
    }

    @Test
    func conflictingMeasuredDirectionsAreNotCalledCharging() {
        let snapshot = makeTelemetrySnapshot(
            isCharging: true,
            batteryCurrentA: -1,
            batteryPowerW: -10
        )

        #expect(snapshot.batteryFlowEvidence == .conflicted)
        #expect(!snapshot.isBatteryChargingForDisplay)
        #expect(!snapshot.isBatteryDischargingForDisplay)
    }

    @Test
    func chargingFlagIsUsedOnlyWhenMeasurementsAreUnavailable() {
        let unavailable = makeTelemetrySnapshot(
            isCharging: true,
            batteryCurrentA: nil,
            batteryPowerW: nil
        )
        let measuredCalm = makeTelemetrySnapshot(
            isCharging: true,
            batteryCurrentA: 0,
            batteryPowerW: 0
        )

        #expect(unavailable.batteryFlowEvidence == .charging)
        #expect(measuredCalm.batteryFlowEvidence == .calm)
    }

    @Test
    func manualHoldSurvivesASingleTransientAssist() {
        var tracker = PowerStateTracker(configuration: configuration)
        _ = tracker.resolve(calmSnapshot(at: 0))
        let established = tracker.resolve(calmSnapshot(at: 12))

        let transient = tracker.resolve(
            assistSnapshot(
                at: 15,
                isCharging: true,
                batteryLevel: 81,
                policy: .manualLimit(targetPercent: 80)
            )
        )
        let recovered = tracker.resolve(calmSnapshot(at: 18))

        #expect(
            established.managedChargingState
                == .holdingAtLimit(targetPercent: 80)
        )
        #expect(transient.batteryFlowEvidence == .discharging)
        #expect(
            transient.managedChargingState
                == .holdingAtLimit(targetPercent: 80)
        )
        #expect(transient.powerDeliveryState == .transientBatteryAssist)
        #expect(transient.externalPowerState == .holding)
        #expect(
            recovered.managedChargingState
                == .holdingAtLimit(targetPercent: 80)
        )
        #expect(recovered.powerDeliveryState == .normal)
    }

    @Test
    func sustainedAssistEventuallyExitsManualHold() {
        var tracker = PowerStateTracker(configuration: configuration)
        _ = tracker.resolve(calmSnapshot(at: 0))
        _ = tracker.resolve(calmSnapshot(at: 12))
        _ = tracker.resolve(assistSnapshot(at: 15))
        _ = tracker.resolve(assistSnapshot(at: 24))
        let snapshot = assistSnapshot(at: 30)
        let sustained = tracker.resolve(snapshot)

        #expect(sustained.powerDeliveryState == .sustainedShortfall)
        #expect(
            sustained.managedChargingState
                == .limitConfigured(targetPercent: 80)
        )
        #expect(sustained.externalPowerState == .connected)
        #expect(
            snapshot.statusHeadline(resolvedState: sustained)
                == L10n.text("status.adapterBatteryAssist")
        )
        #expect(
            snapshot.statusSubheadline(resolvedState: sustained)
                == L10n.tr(
                    "status.subheadline.deficit",
                    Formatters.power(18)
                )
        )
    }

    @Test
    func confirmedNegotiatedShortfallTakesPriorityOverNeutralPolicyState() {
        var tracker = PowerStateTracker(configuration: configuration)
        _ = tracker.resolve(negotiatedLowAssistSnapshot(at: 0))
        _ = tracker.resolve(negotiatedLowAssistSnapshot(at: 10))
        let snapshot = negotiatedLowAssistSnapshot(at: 15)
        let sustained = tracker.resolve(snapshot)

        #expect(sustained.powerDeliveryState == .sustainedShortfall)
        #expect(
            sustained.managedChargingState
                == .limitConfigured(targetPercent: 80)
        )
        #expect(
            snapshot.statusHeadline(resolvedState: sustained)
                == L10n.text("status.adapterBatteryAssist")
        )
        #expect(
            snapshot.statusSubheadline(resolvedState: sustained)
                == L10n.tr(
                    "status.subheadline.inputVsLoad",
                    Formatters.power(20),
                    Formatters.power(23)
                )
        )
    }

    @Test
    func reductionRequiresSustainedDischargeAboveTheTarget() {
        var tracker = PowerStateTracker(configuration: configuration)

        let first = tracker.resolve(
            assistSnapshot(
                at: 0,
                batteryLevel: 90,
                policy: .manualLimit(targetPercent: 80)
            )
        )
        _ = tracker.resolve(
            assistSnapshot(
                at: 10,
                batteryLevel: 90,
                policy: .manualLimit(targetPercent: 80)
            )
        )
        let beforeBoundary = tracker.resolve(
            assistSnapshot(
                at: 14,
                batteryLevel: 90,
                policy: .manualLimit(targetPercent: 80)
            )
        )
        let confirmed = tracker.resolve(
            assistSnapshot(
                at: 15,
                batteryLevel: 90,
                policy: .manualLimit(targetPercent: 80)
            )
        )

        #expect(
            first.managedChargingState
                == .limitConfigured(targetPercent: 80)
        )
        #expect(
            beforeBoundary.managedChargingState
                == .limitConfigured(targetPercent: 80)
        )
        #expect(
            confirmed.managedChargingState
                == .reducingToLimit(targetPercent: 80)
        )
        #expect(confirmed.powerDeliveryState == .normal)
    }

    @Test
    func confirmedAdapterShortfallIsNotCalledLimitReduction() {
        var tracker = PowerStateTracker(configuration: configuration)
        let first = saturatedAssistSnapshot(at: 0)
        let sustained = saturatedAssistSnapshot(at: 15)

        _ = tracker.resolve(first)
        _ = tracker.resolve(saturatedAssistSnapshot(at: 10))
        let resolved = tracker.resolve(sustained)

        #expect(first.hasClearAdapterCapacityShortfall)
        #expect(resolved.powerDeliveryState == .sustainedShortfall)
        #expect(
            resolved.managedChargingState
                == .limitConfigured(targetPercent: 80)
        )
    }

    @Test
    func optimizedHoldAlsoSurvivesTransientAssist() {
        var tracker = PowerStateTracker(configuration: configuration)
        _ = tracker.resolve(
            calmSnapshot(at: 0, policy: .optimizedCharging)
        )
        _ = tracker.resolve(
            calmSnapshot(at: 12, policy: .optimizedCharging)
        )
        let assist = assistSnapshot(
            at: 15,
            policy: .optimizedCharging
        )
        let transient = tracker.resolve(assist)

        #expect(transient.managedChargingState == .optimizedHold)
        #expect(transient.powerDeliveryState == .transientBatteryAssist)
        #expect(transient.externalPowerState == .holding)
        #expect(
            assist.statusSubheadline(resolvedState: transient)
                == L10n.text(
                    "status.subheadline.optimizedCharging.transientAssist"
                )
        )
    }

    @Test
    func manualHoldSurvivesAChargingReboundButNotPersistentCharging() {
        var tracker = PowerStateTracker(configuration: configuration)
        _ = tracker.resolve(calmSnapshot(at: 0))
        _ = tracker.resolve(calmSnapshot(at: 12))

        let rebound = tracker.resolve(chargingSnapshot(at: 15))
        let recovered = tracker.resolve(calmSnapshot(at: 18))

        #expect(
            rebound.managedChargingState
                == .holdingAtLimit(targetPercent: 80)
        )
        #expect(rebound.externalPowerState == .holding)
        #expect(
            recovered.managedChargingState
                == .holdingAtLimit(targetPercent: 80)
        )

        _ = tracker.resolve(chargingSnapshot(at: 21))
        let beforeBoundary = tracker.resolve(chargingSnapshot(at: 26))
        let confirmed = tracker.resolve(chargingSnapshot(at: 27))

        #expect(
            beforeBoundary.managedChargingState
                == .holdingAtLimit(targetPercent: 80)
        )
        #expect(beforeBoundary.externalPowerState == .holding)
        #expect(
            confirmed.managedChargingState
                == .chargingToLimit(targetPercent: 80)
        )
        #expect(confirmed.externalPowerState == .charging)
    }

    @Test
    func sustainedShortfallRequiresConfirmedRecoveryFromUnknownFlow() {
        var tracker = PowerStateTracker(configuration: configuration)
        _ = tracker.resolve(assistSnapshot(at: 0))
        _ = tracker.resolve(assistSnapshot(at: 10))
        let sustained = tracker.resolve(assistSnapshot(at: 15))
        let firstUnknown = tracker.resolve(conflictedSnapshot(at: 18))
        let persistentUnknown = tracker.resolve(conflictedSnapshot(at: 24))

        #expect(sustained.powerDeliveryState == .sustainedShortfall)
        #expect(firstUnknown.powerDeliveryState == .sustainedShortfall)
        #expect(persistentUnknown.powerDeliveryState == .unknown)
    }

    @Test
    func resumedDischargeDoesNotRestartGraceAfterOneUnknownSample() {
        var tracker = PowerStateTracker(configuration: configuration)
        _ = tracker.resolve(assistSnapshot(at: 0))
        _ = tracker.resolve(assistSnapshot(at: 10))
        _ = tracker.resolve(assistSnapshot(at: 15))
        let unknown = tracker.resolve(conflictedSnapshot(at: 18))
        let resumed = tracker.resolve(assistSnapshot(at: 21))

        #expect(unknown.powerDeliveryState == .sustainedShortfall)
        #expect(resumed.powerDeliveryState == .sustainedShortfall)
    }

    @Test
    func unknownFlowDoesNotCountTowardCalmRecovery() {
        var tracker = PowerStateTracker(configuration: configuration)
        _ = tracker.resolve(assistSnapshot(at: 0))
        _ = tracker.resolve(assistSnapshot(at: 10))
        _ = tracker.resolve(assistSnapshot(at: 15))
        _ = tracker.resolve(conflictedSnapshot(at: 18))
        let firstCalmSnapshot = calmSnapshot(at: 24)
        let firstCalm = tracker.resolve(firstCalmSnapshot)
        let recovered = tracker.resolve(calmSnapshot(at: 30))
        let firstCalmDiagnostics = firstCalmSnapshot.diagnostics(
            resolvedState: firstCalm
        )

        #expect(firstCalm.powerDeliveryState == .sustainedShortfall)
        #expect(firstCalm.confirmedShortfall?.deficitW == 18)
        #expect(
            firstCalmSnapshot.statusSubheadline(
                resolvedState: firstCalm
            ) == L10n.tr(
                "status.subheadline.deficit",
                Formatters.power(18)
            )
        )
        #expect(
            firstCalmDiagnostics.contains {
                $0.title == L10n.text("diag.slowCharger.title")
            }
        )
        #expect(
            firstCalmSnapshot.menuBarSymbolName(
                using: firstCalmDiagnostics,
                externalPowerState: firstCalm.externalPowerState
            ) == "exclamationmark.triangle.fill"
        )
        #expect(recovered.powerDeliveryState == .normal)
        #expect(recovered.confirmedShortfall == nil)
    }

    @Test
    func sustainedDischargeNeedsCorroboratingDeliveryEvidence() {
        var tracker = PowerStateTracker(configuration: configuration)
        _ = tracker.resolve(uncorroboratedAssistSnapshot(at: 0))
        _ = tracker.resolve(uncorroboratedAssistSnapshot(at: 10))
        let resolved = tracker.resolve(uncorroboratedAssistSnapshot(at: 15))

        #expect(resolved.batteryFlowEvidence == .discharging)
        #expect(resolved.powerDeliveryState == .unknown)
        #expect(resolved.powerDeliveryState != .sustainedShortfall)
    }

    @Test
    func oneCorroboratingSampleDoesNotConfirmAnOldAssistTimer() {
        var tracker = PowerStateTracker(configuration: configuration)
        _ = tracker.resolve(uncorroboratedAssistSnapshot(at: 0))
        _ = tracker.resolve(uncorroboratedAssistSnapshot(at: 10))
        let boundary = tracker.resolve(assistSnapshot(at: 15))
        let beforeConfirmation = tracker.resolve(assistSnapshot(at: 20))
        let confirmed = tracker.resolve(assistSnapshot(at: 21))

        #expect(boundary.powerDeliveryState == .unknown)
        #expect(beforeConfirmation.powerDeliveryState == .unknown)
        #expect(confirmed.powerDeliveryState == .sustainedShortfall)
    }

    @Test
    func smallBatteryDriftDoesNotPrearmARealAssistTimer() {
        var tracker = PowerStateTracker(configuration: configuration)
        _ = tracker.resolve(smallDriftSnapshot(at: 0))
        let holding = tracker.resolve(smallDriftSnapshot(at: 12))
        let prolongedDrift = tracker.resolve(smallDriftSnapshot(at: 15))
        let firstMaterialAssist = tracker.resolve(assistSnapshot(at: 18))

        #expect(holding.batteryFlowEvidence == .discharging)
        #expect(
            holding.managedChargingState
                == .holdingAtLimit(targetPercent: 80)
        )
        #expect(holding.externalPowerState == .holding)
        #expect(prolongedDrift.powerDeliveryState == .normal)
        #expect(
            prolongedDrift.managedChargingState
                == .holdingAtLimit(targetPercent: 80)
        )
        #expect(prolongedDrift.externalPowerState == .holding)
        #expect(
            firstMaterialAssist.powerDeliveryState
                == .transientBatteryAssist
        )
        #expect(
            firstMaterialAssist.managedChargingState
                == .holdingAtLimit(targetPercent: 80)
        )
    }

    @Test
    func repeatedIdenticalTimestampsDoNotConfirmHold() {
        var tracker = PowerStateTracker(configuration: configuration)
        var resolved: ResolvedPowerState?

        for _ in 0..<10 {
            resolved = tracker.resolve(calmSnapshot(at: 0))
        }

        #expect(
            resolved?.managedChargingState
                == .limitConfigured(targetPercent: 80)
        )
        #expect(resolved?.externalPowerState == .connected)
    }

    @Test
    func sparseObservationGapDoesNotConfirmTemporalEvidence() {
        var tracker = PowerStateTracker(configuration: configuration)
        _ = tracker.resolve(calmSnapshot(at: 0))
        let afterSparseGap = tracker.resolve(calmSnapshot(at: 20))

        #expect(
            afterSparseGap.managedChargingState
                == .limitConfigured(targetPercent: 80)
        )
        #expect(afterSparseGap.externalPowerState == .connected)
    }

    @Test
    func interactiveAndBackgroundCadencesReachTheSameTimedHold() {
        var interactive = PowerStateTracker(configuration: configuration)
        var background = PowerStateTracker(configuration: configuration)
        var interactiveState: ResolvedPowerState?
        var backgroundState: ResolvedPowerState?

        for timestamp in stride(from: 0.0, through: 18.0, by: 3.0) {
            interactiveState = interactive.resolve(
                calmSnapshot(at: timestamp)
            )
        }
        interactiveState = interactive.resolve(calmSnapshot(at: 20))

        for timestamp in [0.0, 10.0, 20.0] {
            backgroundState = background.resolve(
                calmSnapshot(at: timestamp)
            )
        }

        #expect(interactiveState?.externalPowerState == .holding)
        #expect(backgroundState?.externalPowerState == .holding)
        #expect(
            interactiveState?.managedChargingState
                == backgroundState?.managedChargingState
        )
    }

    @Test
    func longObservationGapAndTargetChangeResetEvidence() {
        var tracker = PowerStateTracker(configuration: configuration)
        _ = tracker.resolve(calmSnapshot(at: 0))
        let holding = tracker.resolve(calmSnapshot(at: 12))
        let afterGap = tracker.resolve(calmSnapshot(at: 40))
        let afterTargetChange = tracker.resolve(
            calmSnapshot(
                at: 43,
                batteryLevel: 90,
                policy: .manualLimit(targetPercent: 90)
            )
        )

        #expect(holding.externalPowerState == .holding)
        #expect(afterGap.externalPowerState == .connected)
        #expect(
            afterTargetChange.managedChargingState
                == .limitConfigured(targetPercent: 90)
        )
    }

    @Test
    func unavailablePolicyGraceIsBounded() {
        var tracker = PowerStateTracker(configuration: configuration)
        _ = tracker.resolve(calmSnapshot(at: 0))
        _ = tracker.resolve(calmSnapshot(at: 12))
        let withinGrace = tracker.resolve(
            calmSnapshot(at: 15, policy: .unavailable)
        )
        _ = tracker.resolve(
            calmSnapshot(at: 25, policy: .unavailable)
        )
        let expired = tracker.resolve(
            calmSnapshot(at: 31, policy: .unavailable)
        )

        #expect(
            withinGrace.managedChargingState
                == .holdingAtLimit(targetPercent: 80)
        )
        #expect(expired.managedChargingState == nil)
    }

    @Test
    func unavailablePolicyIsNotReusedAcrossALongObservationGap() {
        var tracker = PowerStateTracker(configuration: configuration)
        _ = tracker.resolve(calmSnapshot(at: 0))
        _ = tracker.resolve(calmSnapshot(at: 12))

        let afterGap = tracker.resolve(
            calmSnapshot(at: 40, policy: .unavailable)
        )

        #expect(afterGap.managedChargingState == nil)
        #expect(afterGap.externalPowerState == .connected)
    }

    @Test
    func disconnectClearsManagedStateImmediately() {
        var tracker = PowerStateTracker(configuration: configuration)
        _ = tracker.resolve(calmSnapshot(at: 0))
        _ = tracker.resolve(calmSnapshot(at: 12))
        let disconnected = tracker.resolve(
            makeTelemetrySnapshot(
                timestamp: date(15),
                powerSource: .battery,
                externalConnected: false,
                timeToEmptyMinutes: 120,
                batteryCurrentA: -1,
                batteryPowerW: 10,
                adapterInputPowerW: 0,
                systemLoadW: 10,
                adapterMaxPowerW: nil,
                chargingPolicyStatus: .manualLimit(targetPercent: 80)
            )
        )

        #expect(disconnected.managedChargingState == nil)
        #expect(disconnected.externalPowerState == .onBattery)
    }

    private func calmSnapshot(
        at seconds: TimeInterval,
        batteryLevel: Double = 80,
        policy: ObservedChargingPolicyStatus = .manualLimit(
            targetPercent: 80
        )
    ) -> TelemetrySnapshot {
        makeTelemetrySnapshot(
            timestamp: date(seconds),
            batteryLevel: batteryLevel,
            batteryCurrentA: 0,
            batteryPowerW: 0,
            adapterInputPowerW: 20,
            systemLoadW: 20,
            adapterMaxPowerW: 96,
            chargingPolicyStatus: policy
        )
    }

    private func assistSnapshot(
        at seconds: TimeInterval,
        isCharging: Bool = false,
        batteryLevel: Double = 80,
        policy: ObservedChargingPolicyStatus = .manualLimit(
            targetPercent: 80
        )
    ) -> TelemetrySnapshot {
        makeTelemetrySnapshot(
            timestamp: date(seconds),
            batteryLevel: batteryLevel,
            isCharging: isCharging,
            batteryCurrentA: -1.5,
            batteryPowerW: 18,
            adapterInputPowerW: 20,
            systemLoadW: 38,
            adapterMaxPowerW: 96,
            chargingPolicyStatus: policy
        )
    }

    private func chargingSnapshot(
        at seconds: TimeInterval
    ) -> TelemetrySnapshot {
        makeTelemetrySnapshot(
            timestamp: date(seconds),
            batteryLevel: 80,
            isCharging: true,
            batteryCurrentA: 1,
            batteryPowerW: -12,
            adapterInputPowerW: 32,
            systemLoadW: 20,
            adapterMaxPowerW: 96,
            chargingPolicyStatus: .manualLimit(targetPercent: 80)
        )
    }

    private func conflictedSnapshot(
        at seconds: TimeInterval
    ) -> TelemetrySnapshot {
        makeTelemetrySnapshot(
            timestamp: date(seconds),
            batteryLevel: 80,
            isCharging: true,
            batteryCurrentA: 1,
            batteryPowerW: 18,
            adapterInputPowerW: 20,
            systemLoadW: 38,
            adapterMaxPowerW: 96,
            chargingPolicyStatus: .manualLimit(targetPercent: 80)
        )
    }

    private func uncorroboratedAssistSnapshot(
        at seconds: TimeInterval
    ) -> TelemetrySnapshot {
        makeTelemetrySnapshot(
            timestamp: date(seconds),
            batteryLevel: 80,
            batteryCurrentA: -1.5,
            batteryPowerW: 18,
            adapterInputPowerW: 38,
            systemLoadW: 38,
            adapterMaxPowerW: 96,
            chargingPolicyStatus: .manualLimit(targetPercent: 80)
        )
    }

    private func negotiatedLowAssistSnapshot(
        at seconds: TimeInterval
    ) -> TelemetrySnapshot {
        makeTelemetrySnapshot(
            timestamp: date(seconds),
            batteryLevel: 80,
            batteryCurrentA: -0.5,
            batteryPowerW: 5,
            adapterInputPowerW: 20,
            systemLoadW: 23,
            adapterMaxPowerW: 96,
            chargingPolicyStatus: .manualLimit(targetPercent: 80)
        )
    }

    private func smallDriftSnapshot(
        at seconds: TimeInterval
    ) -> TelemetrySnapshot {
        makeTelemetrySnapshot(
            timestamp: date(seconds),
            batteryLevel: 80,
            batteryCurrentA: -0.04,
            batteryPowerW: 0.5,
            adapterInputPowerW: 20,
            systemLoadW: 20,
            adapterMaxPowerW: 96,
            chargingPolicyStatus: .manualLimit(targetPercent: 80)
        )
    }

    private func saturatedAssistSnapshot(
        at seconds: TimeInterval
    ) -> TelemetrySnapshot {
        makeTelemetrySnapshot(
            timestamp: date(seconds),
            batteryLevel: 90,
            batteryCurrentA: -1.5,
            batteryPowerW: 20,
            adapterInputPowerW: 20,
            systemLoadW: 40,
            adapterMaxPowerW: 20,
            chargingPolicyStatus: .manualLimit(targetPercent: 80)
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }
}
