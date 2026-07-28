import Foundation

enum PowerDeliveryState: Equatable, Sendable {
    case normal
    case transientBatteryAssist
    case sustainedShortfall
    case unknown
}

struct ConfirmedPowerDeliveryShortfall: Equatable, Sendable {
    let deficitW: Double
    let adapterInputPowerW: Double
    let systemLoadW: Double

    init?(snapshot: TelemetrySnapshot) {
        guard snapshot.hasCorroboratedPowerDeliveryShortfall,
              let deficitW = snapshot.estimatedPowerDeficitW,
              let adapterInputPowerW = snapshot.adapterInputPowerW,
              let systemLoadW = snapshot.systemLoadW else {
            return nil
        }

        self.deficitW = deficitW
        self.adapterInputPowerW = adapterInputPowerW
        self.systemLoadW = systemLoadW
    }
}

struct ResolvedPowerState: Equatable, Sendable {
    let batteryFlowEvidence: BatteryFlowEvidence
    let managedChargingState: ManagedChargingState?
    let powerDeliveryState: PowerDeliveryState
    let externalPowerState: ExternalPowerState
    let confirmedShortfall: ConfirmedPowerDeliveryShortfall?

    var shouldSuppressPowerDeliveryWarnings: Bool {
        powerDeliveryState != .sustainedShortfall
    }
}

struct PowerStateHysteresisConfiguration: Equatable, Sendable {
    let holdConfirmation: TimeInterval
    let transientAssistGrace: TimeInterval
    let shortfallEvidenceConfirmation: TimeInterval
    let reductionConfirmation: TimeInterval
    let recoveryConfirmation: TimeInterval
    let unavailablePolicyGrace: TimeInterval
    let maximumObservationGap: TimeInterval

    init(
        holdConfirmation: TimeInterval = 12,
        transientAssistGrace: TimeInterval = 15,
        shortfallEvidenceConfirmation: TimeInterval = 6,
        reductionConfirmation: TimeInterval = 15,
        recoveryConfirmation: TimeInterval = 6,
        unavailablePolicyGrace: TimeInterval = 15,
        maximumObservationGap: TimeInterval = 20
    ) {
        self.holdConfirmation = max(holdConfirmation, 0)
        self.transientAssistGrace = max(transientAssistGrace, 0)
        self.shortfallEvidenceConfirmation = max(
            shortfallEvidenceConfirmation,
            0
        )
        self.reductionConfirmation = max(reductionConfirmation, 0)
        self.recoveryConfirmation = max(recoveryConfirmation, 0)
        self.unavailablePolicyGrace = max(unavailablePolicyGrace, 0)
        self.maximumObservationGap = max(maximumObservationGap, 0)
    }
}

/// Stabilizes causal charging explanations without delaying the latest physical
/// power-flow diagram.
///
/// The tracker consumes snapshot timestamps rather than sample counts so manual
/// refreshes and the 3-second/10-second refresh cadences share the same rules.
struct PowerStateTracker: Sendable {
    private enum PolicyIdentity: Equatable, Sendable {
        case manualLimit(Int)
        case optimizedCharging
        case inactive
    }

    private let configuration: PowerStateHysteresisConfiguration
    private var lastTimestamp: Date?
    private var lastAvailablePolicy: ObservedChargingPolicyStatus?
    private var unavailableSince: Date?
    private var policyIdentity: PolicyIdentity?
    private var stableManagedState: ManagedChargingState?
    private var managedCandidate: ManagedChargingState?
    private var managedCandidateSince: Date?
    private var physicalHoldSince: Date?
    private var assistSince: Date?
    private var shortfallEvidenceSince: Date?
    private var recoverySince: Date?
    private var uncertainSince: Date?
    private var deliveryState: PowerDeliveryState = .normal
    private var confirmedShortfall: ConfirmedPowerDeliveryShortfall?

    init(
        configuration: PowerStateHysteresisConfiguration = .init()
    ) {
        self.configuration = configuration
    }

    mutating func reset() {
        lastTimestamp = nil
        lastAvailablePolicy = nil
        unavailableSince = nil
        policyIdentity = nil
        stableManagedState = nil
        managedCandidate = nil
        managedCandidateSince = nil
        physicalHoldSince = nil
        assistSince = nil
        shortfallEvidenceSince = nil
        recoverySince = nil
        uncertainSince = nil
        deliveryState = .normal
        confirmedShortfall = nil
    }

    mutating func resolve(
        _ snapshot: TelemetrySnapshot
    ) -> ResolvedPowerState {
        let timestamp = prepareForObservation(at: snapshot.timestamp)

        guard snapshot.externalConnected else {
            let flow = snapshot.batteryFlowEvidence
            reset()
            lastTimestamp = timestamp
            return ResolvedPowerState(
                batteryFlowEvidence: flow,
                managedChargingState: nil,
                powerDeliveryState: .normal,
                externalPowerState: .onBattery,
                confirmedShortfall: nil
            )
        }

        let effectivePolicy = resolveEffectivePolicy(
            snapshot.chargingPolicyStatus,
            at: timestamp
        )
        updatePolicyIdentity(
            for: effectivePolicy,
            at: timestamp
        )

        let policySnapshot = snapshot.withChargingPolicyStatus(effectivePolicy)
        let flow = policySnapshot.batteryFlowEvidence
        let instantaneousManagedState =
            policySnapshot.managedChargingState
        let managedDischargeContext = isManagedDischargeContext(
            snapshot: policySnapshot,
            instantaneousState: instantaneousManagedState
        )

        updateDeliveryState(
            snapshot: policySnapshot,
            flow: flow,
            managedDischargeContext: managedDischargeContext,
            at: timestamp
        )
        updateManagedState(
            candidate: instantaneousManagedState,
            effectivePolicy: effectivePolicy,
            at: timestamp
        )

        if stableManagedState?.isHolding == true,
           deliveryState == .sustainedShortfall {
            stableManagedState = fallbackManagedState(for: effectivePolicy)
            clearManagedCandidate()
        }

        if stableManagedStateExplainsDischarge,
           !policySnapshot.hasClearAdapterCapacityShortfall {
            deliveryState = .normal
            assistSince = nil
            shortfallEvidenceSince = nil
            recoverySince = nil
            uncertainSince = nil
            confirmedShortfall = nil
        }

        let externalPowerState = resolveExternalPowerState(
            snapshot: policySnapshot,
            flow: flow,
            at: timestamp
        )
        lastTimestamp = timestamp

        return ResolvedPowerState(
            batteryFlowEvidence: flow,
            managedChargingState: stableManagedState
                ?? fallbackManagedState(for: effectivePolicy),
            powerDeliveryState: deliveryState,
            externalPowerState: externalPowerState,
            confirmedShortfall: confirmedShortfall
        )
    }

    private mutating func prepareForObservation(at timestamp: Date) -> Date {
        guard let lastTimestamp else {
            return timestamp
        }

        let gap = timestamp.timeIntervalSince(lastTimestamp)
        if gap <= 0 {
            return lastTimestamp
        }
        if gap >= configuration.maximumObservationGap {
            resetTemporalEvidence()
        }
        return timestamp
    }

    private mutating func resolveEffectivePolicy(
        _ observedPolicy: ObservedChargingPolicyStatus?,
        at timestamp: Date
    ) -> ObservedChargingPolicyStatus? {
        guard let observedPolicy else {
            lastAvailablePolicy = nil
            unavailableSince = nil
            return nil
        }

        switch observedPolicy {
        case .manualLimit, .optimizedCharging, .inactive:
            lastAvailablePolicy = observedPolicy
            unavailableSince = nil
            return observedPolicy
        case .unavailable:
            if unavailableSince == nil {
                unavailableSince = timestamp
            }
            guard let unavailableSince,
                  elapsed(from: unavailableSince, to: timestamp)
                    <= configuration.unavailablePolicyGrace else {
                lastAvailablePolicy = nil
                return nil
            }
            return lastAvailablePolicy
        }
    }

    private mutating func updatePolicyIdentity(
        for policy: ObservedChargingPolicyStatus?,
        at timestamp: Date
    ) {
        let newIdentity = identity(for: policy)
        guard newIdentity != policyIdentity else {
            return
        }

        policyIdentity = newIdentity
        stableManagedState = nil
        clearManagedCandidate()
        physicalHoldSince = nil
        assistSince = nil
        shortfallEvidenceSince = nil
        recoverySince = nil
        uncertainSince = nil
        deliveryState = .normal
        confirmedShortfall = nil

        if newIdentity == .inactive || newIdentity == nil {
            unavailableSince = policy == .unavailable ? timestamp : nil
        }
    }

    private func identity(
        for policy: ObservedChargingPolicyStatus?
    ) -> PolicyIdentity? {
        switch policy {
        case let .manualLimit(targetPercent):
            guard (1...100).contains(targetPercent) else {
                return nil
            }
            return .manualLimit(targetPercent)
        case .optimizedCharging:
            return .optimizedCharging
        case .inactive:
            return .inactive
        case .unavailable, nil:
            return nil
        }
    }

    private mutating func updateDeliveryState(
        snapshot: TelemetrySnapshot,
        flow: BatteryFlowEvidence,
        managedDischargeContext: Bool,
        at timestamp: Date
    ) {
        let batteryIsMateriallyAssisting =
            snapshot.hasMaterialBatteryAssist
        if (
            flow == .conflicted
                || flow == .unavailable
        ) && !batteryIsMateriallyAssisting {
            recoverySince = nil
            if deliveryState == .sustainedShortfall {
                if uncertainSince == nil {
                    uncertainSince = timestamp
                }
                if let uncertainSince,
                   elapsed(from: uncertainSince, to: timestamp)
                       >= configuration.recoveryConfirmation {
                    deliveryState = .unknown
                    assistSince = nil
                    shortfallEvidenceSince = nil
                    self.uncertainSince = nil
                    confirmedShortfall = nil
                }
                return
            }

            assistSince = nil
            shortfallEvidenceSince = nil
            uncertainSince = nil
            deliveryState = .unknown
            confirmedShortfall = nil
            return
        }

        if batteryIsMateriallyAssisting && !managedDischargeContext {
            recoverySince = nil
            if assistSince == nil {
                assistSince = timestamp
                shortfallEvidenceSince = nil
            }

            let corroboratesShortfall =
                snapshot.hasCorroboratedPowerDeliveryShortfall
            if corroboratesShortfall {
                if shortfallEvidenceSince == nil {
                    shortfallEvidenceSince = timestamp
                }
            } else if deliveryState != .sustainedShortfall {
                shortfallEvidenceSince = nil
            }

            if deliveryState == .sustainedShortfall {
                if corroboratesShortfall {
                    uncertainSince = nil
                    confirmedShortfall = ConfirmedPowerDeliveryShortfall(
                        snapshot: snapshot
                    ) ?? confirmedShortfall
                } else {
                    if uncertainSince == nil {
                        uncertainSince = timestamp
                    }
                    if let uncertainSince,
                       elapsed(from: uncertainSince, to: timestamp)
                           >= configuration.recoveryConfirmation {
                        deliveryState = .unknown
                        assistSince = nil
                        shortfallEvidenceSince = nil
                        self.uncertainSince = nil
                        confirmedShortfall = nil
                    }
                }
                return
            }

            let assistIsConfirmed = assistSince.map {
                elapsed(from: $0, to: timestamp)
                    >= configuration.transientAssistGrace
            } ?? false
            let shortfallEvidenceIsConfirmed =
                shortfallEvidenceSince.map {
                    elapsed(from: $0, to: timestamp)
                        >= configuration.shortfallEvidenceConfirmation
                } ?? false

            if assistIsConfirmed && shortfallEvidenceIsConfirmed {
                deliveryState = .sustainedShortfall
                uncertainSince = nil
                confirmedShortfall = ConfirmedPowerDeliveryShortfall(
                    snapshot: snapshot
                )
            } else if assistIsConfirmed {
                deliveryState = .unknown
                uncertainSince = nil
                confirmedShortfall = nil
            } else {
                deliveryState = .transientBatteryAssist
                uncertainSince = nil
                confirmedShortfall = nil
            }
            return
        }

        assistSince = nil
        shortfallEvidenceSince = nil
        uncertainSince = nil
        if deliveryState == .sustainedShortfall {
            if recoverySince == nil {
                recoverySince = timestamp
            }
            if let recoverySince,
               elapsed(from: recoverySince, to: timestamp)
                    >= configuration.recoveryConfirmation {
                deliveryState = .normal
                self.recoverySince = nil
                confirmedShortfall = nil
            }
            return
        }

        recoverySince = nil
        deliveryState = .normal
        confirmedShortfall = nil
    }

    private func isManagedDischargeContext(
        snapshot: TelemetrySnapshot,
        instantaneousState: ManagedChargingState?
    ) -> Bool {
        let instantaneousReduction: Bool
        if case .reducingToLimit = instantaneousState {
            instantaneousReduction = true
        } else {
            instantaneousReduction = false
        }

        let stabilizedReduction: Bool
        if case .reducingToLimit = stableManagedState {
            stabilizedReduction = true
        } else {
            stabilizedReduction = false
        }

        let stabilizedOptimizedManagement: Bool
        if case .optimizedActive = stableManagedState {
            stabilizedOptimizedManagement = true
        } else {
            stabilizedOptimizedManagement = false
        }

        guard instantaneousReduction
                || stabilizedReduction
                || stabilizedOptimizedManagement else {
            return false
        }
        return !snapshot.hasClearAdapterCapacityShortfall
    }

    private var stableManagedStateExplainsDischarge: Bool {
        switch stableManagedState {
        case .reducingToLimit, .optimizedActive:
            true
        case .chargingToLimit, .holdingAtLimit, .limitConfigured,
             .optimizedCharging, .optimizedHold, nil:
            false
        }
    }

    private mutating func updateManagedState(
        candidate: ManagedChargingState?,
        effectivePolicy: ObservedChargingPolicyStatus?,
        at timestamp: Date
    ) {
        guard identity(for: effectivePolicy) != nil,
              identity(for: effectivePolicy) != .inactive else {
            stableManagedState = nil
            clearManagedCandidate()
            return
        }

        if candidate == stableManagedState {
            clearManagedCandidate()
            return
        }

        if managedCandidate != candidate {
            managedCandidate = candidate
            managedCandidateSince = timestamp
        }

        let requiredDuration = confirmationDuration(
            for: candidate,
            previousStableState: stableManagedState
        )
        guard let managedCandidateSince,
              elapsed(from: managedCandidateSince, to: timestamp)
                >= requiredDuration else {
            return
        }

        stableManagedState = candidate
        clearManagedCandidate()
    }

    private func confirmationDuration(
        for candidate: ManagedChargingState?,
        previousStableState: ManagedChargingState?
    ) -> TimeInterval {
        let whileHolding = previousStableState?.isHolding == true
        let whileReducing: Bool
        if case .reducingToLimit = previousStableState {
            whileReducing = true
        } else {
            whileReducing = false
        }

        switch candidate {
        case .holdingAtLimit, .optimizedHold:
            return configuration.holdConfirmation
        case .reducingToLimit:
            return configuration.reductionConfirmation
        case .chargingToLimit, .optimizedCharging:
            return whileHolding || whileReducing
                ? configuration.recoveryConfirmation
                : 0
        case .limitConfigured, .optimizedActive, nil:
            return whileHolding || whileReducing
                ? configuration.transientAssistGrace
                : 0
        }
    }

    private func fallbackManagedState(
        for policy: ObservedChargingPolicyStatus?
    ) -> ManagedChargingState? {
        switch policy {
        case let .manualLimit(targetPercent):
            guard (1...100).contains(targetPercent) else {
                return nil
            }
            return .limitConfigured(targetPercent: targetPercent)
        case .optimizedCharging:
            return .optimizedActive
        case .inactive, .unavailable, nil:
            return nil
        }
    }

    private mutating func resolveExternalPowerState(
        snapshot: TelemetrySnapshot,
        flow: BatteryFlowEvidence,
        at timestamp: Date
    ) -> ExternalPowerState {
        if stableManagedState?.isHolding == true,
           deliveryState != .sustainedShortfall {
            return .holding
        }

        if flow == .charging {
            physicalHoldSince = nil
            return .charging
        }

        guard snapshot.isHoldingBatteryLevelCandidate else {
            physicalHoldSince = nil
            return .connected
        }

        if physicalHoldSince == nil {
            physicalHoldSince = timestamp
        }
        guard let physicalHoldSince,
              elapsed(from: physicalHoldSince, to: timestamp)
                >= configuration.holdConfirmation else {
            return .connected
        }
        return .holding
    }

    private mutating func resetTemporalEvidence() {
        stableManagedState = nil
        clearManagedCandidate()
        physicalHoldSince = nil
        assistSince = nil
        shortfallEvidenceSince = nil
        recoverySince = nil
        uncertainSince = nil
        deliveryState = .normal
        confirmedShortfall = nil
        unavailableSince = nil
        lastAvailablePolicy = nil
    }

    private mutating func clearManagedCandidate() {
        managedCandidate = nil
        managedCandidateSince = nil
    }

    private func elapsed(from start: Date, to end: Date) -> TimeInterval {
        max(end.timeIntervalSince(start), 0)
    }
}
