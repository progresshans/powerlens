import Foundation

enum ManagedChargingState: Equatable, Sendable {
    case chargingToLimit(targetPercent: Int)
    case reducingToLimit(targetPercent: Int)
    case holdingAtLimit(targetPercent: Int)
    case limitConfigured(targetPercent: Int)
    case optimizedCharging
    case optimizedHold
    case optimizedActive

    var suppressesPowerDeliveryWarnings: Bool {
        switch self {
        case .reducingToLimit, .holdingAtLimit, .optimizedHold:
            true
        case .chargingToLimit, .limitConfigured, .optimizedCharging, .optimizedActive:
            false
        }
    }

    var isHolding: Bool {
        switch self {
        case .holdingAtLimit, .optimizedHold:
            true
        case .chargingToLimit, .reducingToLimit, .limitConfigured,
             .optimizedCharging, .optimizedActive:
            false
        }
    }
}

enum BatteryFlowEvidence: Equatable, Sendable {
    case charging
    case calm
    case discharging
    case conflicted
    case unavailable
}

extension TelemetrySnapshot {
    var estimatedPowerDeficitW: Double? {
        guard externalConnected, let systemLoadW, let adapterInputPowerW else { return nil }
        return systemLoadW - adapterInputPowerW
    }

    var batteryChargeInflowW: Double {
        max(-(batteryPowerW ?? 0), 0)
    }

    var batteryFlowEvidence: BatteryFlowEvidence {
        let powerDirection = batteryPowerW.map { power -> BatteryFlowEvidence in
            if power < -PowerStateThresholds.displayChargeInflowW {
                return .charging
            }
            if power > PowerStateThresholds.displayDischargeOutflowW {
                return .discharging
            }
            return .calm
        }
        let currentDirection = batteryCurrentA.map {
            current -> BatteryFlowEvidence in
            if current > PowerStateThresholds.displayChargeCurrentA {
                return .charging
            }
            if current < -PowerStateThresholds.displayDischargeCurrentA {
                return .discharging
            }
            return .calm
        }
        let measuredDirections = [powerDirection, currentDirection].compactMap {
            $0
        }
        let hasCharging = measuredDirections.contains(.charging)
        let hasDischarging = measuredDirections.contains(.discharging)

        if hasCharging && hasDischarging {
            return .conflicted
        }
        if hasCharging {
            return .charging
        }
        if hasDischarging {
            return .discharging
        }
        if !measuredDirections.isEmpty {
            return .calm
        }

        // The system flag is a fallback only when direct flow measurements are
        // unavailable. It can lag behind fast battery-assist transitions.
        return isCharging ? .charging : .unavailable
    }

    /// Prefers the direct battery-power sample when it independently proves
    /// discharge. A near-zero/stale power sample must not mask a material
    /// discharge current observed in the same snapshot.
    var measuredBatteryDischargeW: Double? {
        guard batteryFlowEvidence == .discharging else {
            return nil
        }

        if let batteryPowerW,
           batteryPowerW > PowerStateThresholds.displayDischargeOutflowW {
            return batteryPowerW
        }
        if let batteryCurrentA,
           let batteryVoltageV,
           batteryCurrentA < -PowerStateThresholds.displayDischargeCurrentA,
           batteryVoltageV > 0 {
            return -batteryCurrentA * batteryVoltageV
        }
        return nil
    }

    /// Prefers the direct battery-power sample when it independently proves
    /// charging. A near-zero/stale power sample must not mask a material
    /// charging current observed in the same snapshot.
    var measuredBatteryChargeW: Double? {
        guard batteryFlowEvidence == .charging else {
            return nil
        }

        if let batteryPowerW,
           batteryPowerW < -PowerStateThresholds.displayChargeInflowW {
            return -batteryPowerW
        }
        if let batteryCurrentA,
           let batteryVoltageV,
           batteryCurrentA > PowerStateThresholds.displayChargeCurrentA,
           batteryVoltageV > 0 {
            return batteryCurrentA * batteryVoltageV
        }
        return nil
    }

    var isBatteryChargingForDisplay: Bool {
        batteryFlowEvidence == .charging
    }

    var isBatteryDischargingForDisplay: Bool {
        batteryFlowEvidence == .discharging
    }

    var hasMaterialBatteryAssist: Bool {
        if batteryFlowEvidence == .discharging {
            let powerShowsMaterialDischarge = batteryPowerW.map {
                $0 > PowerStateThresholds.holdBatteryPowerToleranceW
            } ?? false
            let currentShowsMaterialDischarge = batteryCurrentA.map {
                $0 < -PowerStateThresholds.holdBatteryCurrentToleranceA
            } ?? false
            return powerShowsMaterialDischarge
                || currentShowsMaterialDischarge
        }

        // Compatible telemetry has no direct battery-flow measurements. A
        // remaining-time estimate plus a measured delivery deficit is the
        // conservative fallback for material battery assist.
        if batteryFlowEvidence == .unavailable {
            return timeToEmptyMinutes != nil
                && (hasSlowChargerCondition || hasNegotiatedLowCondition)
        }

        return false
    }

    var canInferManualLimitHoldWithoutBatteryFlowMeasurements: Bool {
        guard externalConnected,
              batteryPowerW == nil,
              batteryCurrentA == nil,
              !isBatteryChargingForDisplay,
              timeToFullMinutes == nil,
              timeToEmptyMinutes == nil else {
            return false
        }

        return estimatedPowerDeficitW.map {
            $0 <= PowerStateThresholds.clearPowerDeficitW
        } ?? true
    }

    var ratedHeadroomW: Double? {
        guard externalConnected, let adapterMaxPowerW, let systemLoadW else { return nil }
        return adapterMaxPowerW - systemLoadW
    }

    var isHoldingBatteryLevelCandidate: Bool {
        guard externalConnected else { return false }

        guard timeToFullMinutes == nil,
              timeToEmptyMinutes == nil else {
            return false
        }

        guard batteryFlowEvidence != .charging,
              batteryFlowEvidence != .conflicted else {
            return false
        }

        // Hold candidacy intentionally has a wider tolerance than the
        // instantaneous flow diagram. Small battery drift is handled by the
        // temporal tracker instead of making this predicate unreachable.
        let calmSignals = [
            batteryPowerW.map { abs($0) <= PowerStateThresholds.holdBatteryPowerToleranceW },
            batteryCurrentA.map { abs($0) <= PowerStateThresholds.holdBatteryCurrentToleranceA },
        ].compactMap { $0 }

        if !calmSignals.isEmpty {
            return calmSignals.allSatisfy { $0 }
        }

        return isCharged || (batteryLevel ?? 0) >= 99
    }

    var externalPowerState: ExternalPowerState {
        if !externalConnected {
            return .onBattery
        }

        if isBatteryChargingForDisplay {
            return .charging
        }

        if isHoldingBatteryLevelCandidate {
            return .holding
        }

        return .connected
    }

    var chargerAdequacy: ChargerAdequacy {
        guard externalConnected else { return .disconnected }

        if let deficit = estimatedPowerDeficitW {
            if deficit > 5 {
                return .insufficient
            }
            if deficit > 1.5 {
                return .constrained
            }
        }

        if let headroom = ratedHeadroomW {
            if headroom >= 30 {
                return .ample
            }
            if headroom >= 10 {
                return .adequate
            }
            if headroom >= 0 {
                return .constrained
            }
            return .insufficient
        }

        return .unknown
    }

    var hasSlowChargerCondition: Bool {
        guard externalConnected,
              let deficit = estimatedPowerDeficitW else { return false }
        return deficit > 5
    }

    /// Evidence that a real delivery problem may coexist with a managed
    /// discharge. The adapter must be close to its rated capacity so the
    /// evidence is independent of the battery discharge that the policy may
    /// itself be causing.
    var hasClearAdapterCapacityShortfall: Bool {
        guard externalConnected,
              isBatteryDischargingForDisplay,
              let adapterMaxPowerW,
              let adapterInputPowerW,
              let systemLoadW,
              adapterMaxPowerW > 0 else {
            return false
        }

        let hasClearDeficit = systemLoadW - adapterInputPowerW
            > PowerStateThresholds.clearPowerDeficitW
        let adapterIsSaturated = adapterInputPowerW
            >= adapterMaxPowerW * PowerStateThresholds.adapterSaturationRatio
        return hasClearDeficit && adapterIsSaturated
    }

    var hasNegotiatedLowCondition: Bool {
        guard externalConnected,
              let rated = adapterMaxPowerW,
              let input = adapterInputPowerW,
              let load = systemLoadW,
              rated > 0 else { return false }

        let batteryIsSupportingLoad = batteryPowerW.map { $0 > 2 } ?? false
        let batteryCurrentIsDischarging = batteryCurrentA.map { $0 < -0.15 } ?? false
        let loadMeaningfullyExceedsInput = estimatedPowerDeficitW.map {
            $0 > PowerStateThresholds.negotiatedLowDeficitW
        } ?? false

        return input < rated * 0.55
            && load > input * 0.85
            && (
                batteryIsSupportingLoad
                    || batteryCurrentIsDischarging
                    || loadMeaningfullyExceedsInput
            )
    }

    var hasCorroboratedPowerDeliveryShortfall: Bool {
        guard estimatedPowerDeficitW.map({
            $0 > PowerStateThresholds.negotiatedLowDeficitW
        }) == true else {
            return false
        }

        return hasSlowChargerCondition
            || hasNegotiatedLowCondition
            || hasClearAdapterCapacityShortfall
    }

    /// Interprets the observed macOS charging policy together with the current
    /// physical power flow. Neutral policy states remain distinct from states
    /// that the policy can causally explain.
    var managedChargingState: ManagedChargingState? {
        guard externalConnected, let chargingPolicyStatus else {
            return nil
        }

        switch chargingPolicyStatus {
        case let .manualLimit(targetPercent):
            guard (1...100).contains(targetPercent) else {
                return nil
            }

            let isAtOrBelowSelectedLimit = batteryLevel.map {
                $0 <= Double(targetPercent)
                    + PowerStateThresholds.manualLimitUpperHoldTolerancePercent
            } ?? false

            if isBatteryChargingForDisplay, isAtOrBelowSelectedLimit {
                return .chargingToLimit(targetPercent: targetPercent)
            }

            if hasClearAdapterCapacityShortfall {
                return .limitConfigured(targetPercent: targetPercent)
            }

            if targetPercent < 100,
               isBatteryDischargingForDisplay,
               let batteryLevel,
               batteryLevel
                   > Double(targetPercent)
                       + PowerStateThresholds.manualLimitUpperHoldTolerancePercent {
                return .reducingToLimit(targetPercent: targetPercent)
            }

            let isNearSelectedLimit = batteryLevel.map {
                $0 >= Double(targetPercent)
                    - PowerStateThresholds.manualLimitLowerHoldTolerancePercent
                    && $0 <= Double(targetPercent)
                    + PowerStateThresholds.manualLimitUpperHoldTolerancePercent
            } ?? (targetPercent == 100 && isCharged)

            if (
                isHoldingBatteryLevelCandidate
                    || canInferManualLimitHoldWithoutBatteryFlowMeasurements
            ), isNearSelectedLimit {
                return .holdingAtLimit(targetPercent: targetPercent)
            }

            return .limitConfigured(targetPercent: targetPercent)
        case .optimizedCharging:
            if isBatteryChargingForDisplay {
                return .optimizedCharging
            }

            return isHoldingBatteryLevelCandidate
                ? .optimizedHold
                : .optimizedActive
        case .inactive, .unavailable:
            return nil
        }
    }

    var shouldSuppressPowerDeliveryWarnings: Bool {
        isHoldingBatteryLevelCandidate
            || (managedChargingState?.suppressesPowerDeliveryWarnings ?? false)
    }

    static func stableExternalPowerState(
        for recentSnapshots: [TelemetrySnapshot],
        requiredConsecutiveSamples: Int = 3
    ) -> ExternalPowerState {
        guard let current = recentSnapshots.last else {
            return .connected
        }

        if !current.externalConnected {
            return .onBattery
        }

        if current.isBatteryChargingForDisplay {
            return .charging
        }

        let stableWindow = Array(recentSnapshots.suffix(requiredConsecutiveSamples))
        let levels = stableWindow.compactMap(\.batteryLevel)
        let levelDrift = levels.isEmpty ? 0 : (levels.max() ?? 0) - (levels.min() ?? 0)

        if stableWindow.count >= requiredConsecutiveSamples,
           stableWindow.allSatisfy(\.isHoldingBatteryLevelCandidate),
           levelDrift <= PowerStateThresholds.holdBatteryLevelDriftPercent {
            return .holding
        }

        return .connected
    }
}

private enum PowerStateThresholds {
    static let displayChargeInflowW = 0.35
    static let displayChargeCurrentA = 0.05
    static let displayDischargeOutflowW = 0.35
    static let displayDischargeCurrentA = 0.05
    static let manualLimitLowerHoldTolerancePercent = 5.0
    static let manualLimitUpperHoldTolerancePercent = 1.0
    static let adapterSaturationRatio = 0.8
    static let clearPowerDeficitW = 5.0
    static let negotiatedLowDeficitW = 2.5
    static let holdBatteryPowerToleranceW = 4.0
    static let holdBatteryCurrentToleranceA = 0.2
    static let holdBatteryLevelDriftPercent = 1.0
}
