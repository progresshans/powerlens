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
        case .reducingToLimit, .holdingAtLimit, .optimizedHold,
             .optimizedActive:
            true
        case .chargingToLimit, .limitConfigured, .optimizedCharging:
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

    /// Battery power and battery current are sampled through different
    /// interfaces and may update at different times. Keep the direction useful
    /// for the live flow diagram, but do not treat a large magnitude mismatch
    /// as corroboration for a charger warning.
    var hasConflictingBatteryPowerMeasurements: Bool {
        // A current-and-voltage value repeats the current signal rather than
        // providing an independent power sample, so it cannot conflict with
        // its own source measurement.
        if batteryPowerSource == .currentAndVoltage {
            return batteryFlowEvidence == .conflicted
        }

        guard let batteryPowerW,
              let batteryCurrentA else {
            return batteryFlowEvidence == .conflicted
        }

        guard let batteryVoltageV, batteryVoltageV > 0 else {
            // Keep the current direction available to the live flow diagram,
            // but do not let signals that disagree about material battery flow
            // corroborate a warning when voltage is unavailable and their
            // magnitudes cannot be compared.
            let powerShowsMaterialFlow =
                abs(batteryPowerW)
                    > PowerStateThresholds.holdBatteryPowerToleranceW
            let currentShowsMaterialFlow =
                abs(batteryCurrentA)
                    > PowerStateThresholds.holdBatteryCurrentToleranceA
            return powerShowsMaterialFlow != currentShowsMaterialFlow
                || batteryFlowEvidence == .conflicted
        }

        let currentDerivedPowerW = -batteryCurrentA * batteryVoltageV
        let comparisonMagnitude = max(
            abs(batteryPowerW),
            abs(currentDerivedPowerW)
        )
        guard comparisonMagnitude
                > PowerStateThresholds.powerCoherenceMinimumMagnitudeW else {
            return batteryFlowEvidence == .conflicted
        }

        let allowedDifference = max(
            PowerStateThresholds.powerCoherenceAbsoluteToleranceW,
            comparisonMagnitude
                * PowerStateThresholds.powerCoherenceRelativeTolerance
        )
        return abs(batteryPowerW - currentDerivedPowerW) > allowedDifference
            || batteryFlowEvidence == .conflicted
    }

    /// Checks whether the independently sampled adapter, battery, and system
    /// powers can describe the same physical flow within a deliberately wide
    /// tolerance. A large residual means at least one value is stale, so the
    /// sample can still drive the live diagram but cannot confirm a warning.
    var hasConflictingDischargePowerBalance: Bool {
        guard externalConnected,
              let adapterInputPowerW,
              let systemLoadW,
              let measuredBatteryDischargeW else {
            return false
        }

        let representedLoadW = max(
            adapterInputPowerW + measuredBatteryDischargeW,
            systemLoadW
        )
        let allowedDifference = max(
            PowerStateThresholds.powerBalanceAbsoluteToleranceW,
            representedLoadW
                * PowerStateThresholds.powerBalanceRelativeTolerance
        )
        return abs(
            adapterInputPowerW
                + measuredBatteryDischargeW
                - systemLoadW
        ) > allowedDifference
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
                && (
                    hasMaterialInputDeficit
                        || hasLowInputRelativeToAdapterRating
                )
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

    var hasMaterialInputDeficit: Bool {
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
              !hasConflictingBatteryPowerMeasurements,
              !hasConflictingDischargePowerBalance,
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

    /// Observes that current input is unusually low relative to the adapter's
    /// advertised capacity. This is not proof of a USB-PD negotiation problem:
    /// macOS demand, conversion losses, and asynchronously updated sensors can
    /// produce the same relationship.
    var hasLowInputRelativeToAdapterRating: Bool {
        guard externalConnected,
              let rated = adapterMaxPowerW,
              let input = adapterInputPowerW,
              rated > 0 else { return false }

        return input < rated * 0.55
    }

    var hasCorroboratedPowerDeliveryShortfall: Bool {
        guard !hasConflictingBatteryPowerMeasurements,
              !hasConflictingDischargePowerBalance,
              estimatedPowerDeficitW.map({
                  $0 > PowerStateThresholds.lowInputDeficitW
              }) == true else {
            return false
        }

        return hasMaterialInputDeficit
            || hasLowInputRelativeToAdapterRating
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
               batteryLevel > Double(targetPercent) {
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
    static let lowInputDeficitW = 2.5
    static let holdBatteryPowerToleranceW = 4.0
    static let holdBatteryCurrentToleranceA = 0.2
    static let holdBatteryLevelDriftPercent = 1.0
    static let powerCoherenceMinimumMagnitudeW = 2.0
    static let powerCoherenceAbsoluteToleranceW = 4.0
    static let powerCoherenceRelativeTolerance = 0.5
    static let powerBalanceAbsoluteToleranceW = 5.0
    static let powerBalanceRelativeTolerance = 0.35
}
