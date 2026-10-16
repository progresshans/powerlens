import Foundation

enum PowerFlowFallbackReason: Equatable, Sendable {
    case invalidBalance
    case conflictingDirection
    case missingMeasurement
}

enum PowerFlowSystemPowerSource: Equatable, Sendable {
    case measured
    case powerBalance
    case unavailable
}

/// How a calculated input was kept physically possible. The battery branch
/// absorbs the difference so the displayed values still balance.
enum PowerFlowInputAdjustment: Equatable, Sendable {
    case raisedToZero
    case limitedToAdapterRating
}

/// A balanced presentation anchored to the system sensor whenever available.
/// Raw telemetry remains unchanged for details, history, and diagnostics.
///
/// Captured SMC readings update at different points in their sampling cycle.
/// Displayed input is therefore calculated from the system anchor and battery
/// flow; it is not a reconstruction of an input reading at a guaranteed time.
struct PowerFlowReadings: Equatable, Sendable {
    enum FlowValueSource: Equatable, Sendable {
        case measured
        case currentAndVoltage
        case inputLoadDifference
        case unavailable

        var isDerived: Bool {
            switch self {
            case .currentAndVoltage, .inputLoadDifference: true
            case .measured, .unavailable: false
            }
        }
    }

    private struct BatteryFlowObservation {
        let direction: BatteryFlowEvidence
        let powerW: Double?
        let source: FlowValueSource
    }

    let state: PowerFlowDiagramState
    let observedState: PowerFlowDiagramState
    let observedBatteryDirection: BatteryFlowEvidence
    let isExternalPower: Bool
    let hasBalancedFlow: Bool
    let inputPower: DisplayedPowerMeasurement?
    let batteryPower: DisplayedPowerMeasurement?
    let systemPower: DisplayedPowerMeasurement?
    let systemPowerSource: PowerFlowSystemPowerSource
    let batteryValueSource: FlowValueSource
    let observedBatteryPowerW: Double?
    /// Original source balance is comparison information, never a selector
    /// between a usable system sensor and another displayed system value.
    let candidateSystemPower: DisplayedPowerMeasurement?
    let candidateSystemPowerW: Double?
    let discrepancyW: Double?
    let fallbackReason: PowerFlowFallbackReason?
    /// The route direction taken from SMC battery power alone, when a complete
    /// SMC set is available. Diagnostics keep the combined evidence.
    let smcBatteryDirection: BatteryFlowEvidence?
    let inputAdjustment: PowerFlowInputAdjustment?

    init(snapshot: TelemetrySnapshot) {
        let smcDirection = Self.smcBatteryDirection(snapshot)
        let flowEvidence = smcDirection ?? snapshot.batteryFlowEvidence
        let observation = Self.observeBatteryFlow(snapshot, smcDirection: smcDirection)
        smcBatteryDirection = smcDirection
        let observedState = Self.resolveState(snapshot: snapshot, batteryFlow: observation)
        self.observedState = observedState
        observedBatteryDirection = smcDirection ?? (
            snapshot.externalConnected ? observation.direction : snapshot.batteryFlowEvidence
        )
        var displayState = observedState
        isExternalPower = snapshot.externalConnected
        batteryValueSource = observation.source
        observedBatteryPowerW = observation.powerW
        let observedInput = Self.reading(snapshot.adapterInputPowerW)
        let observedBattery = Self.reading(observation.powerW, isApproximate: observation.source.isDerived)
        let rawSystem = Self.reading(snapshot.systemLoadW)

        let invalidDirectionSensor = snapshot.batteryPowerW.map { !$0.isFinite } == true
            || snapshot.batteryCurrentA.map { !$0.isFinite } == true
        let invalidInput = isExternalPower && snapshot.adapterInputPowerW != nil && observedInput == nil
        let invalidBattery = observation.powerW != nil && observedBattery == nil
        let hasInvalidObservation = invalidDirectionSensor || invalidInput || invalidBattery
        let hasConflict = observedState == .unknown
            || (!isExternalPower && (
                flowEvidence == .conflicted
                    || flowEvidence == .charging
            ))

        var unroundedCandidate: Double?
        var candidate: DisplayedPowerMeasurement?
        switch observedState {
        case .discharging:
            unroundedCandidate = observation.powerW
            candidate = observedBattery
            if candidate == nil, flowEvidence == .calm {
                unroundedCandidate = snapshot.batteryPowerW
                candidate = Self.reading(snapshot.batteryPowerW, isApproximate: snapshot.batteryPowerIsDerived)
            }
        case .charging, .underpowered:
            if let inputW = snapshot.adapterInputPowerW,
               let batteryW = observation.powerW,
               let observedInput, let observedBattery {
                let sign = observedState == .charging ? -1.0 : 1.0
                let balanceW = inputW + sign * batteryW
                unroundedCandidate = balanceW.isFinite ? balanceW : nil
                if balanceW.isFinite, balanceW >= 0 {
                    candidate = Self.reading(
                        (observedInput.watts * 10 + sign * observedBattery.watts * 10) / 10,
                        isApproximate: true
                    )
                }
            }
        case .holding, .directPower:
            if observation.direction == .calm {
                unroundedCandidate = snapshot.adapterInputPowerW
                candidate = observedInput.map { .init(watts: $0.watts, isApproximate: true) }
            }
        case .unknown:
            break
        }
        // A direction conflict cannot establish an observed power balance.
        candidateSystemPower = hasConflict ? nil : candidate
        candidateSystemPowerW = hasConflict ? nil : unroundedCandidate
        if !hasConflict, let unroundedCandidate, let rawW = snapshot.systemLoadW, rawSystem != nil,
           abs(unroundedCandidate - rawW).isFinite {
            discrepancyW = abs(unroundedCandidate - rawW)
        } else {
            discrepancyW = nil
        }

        let usableCandidate = hasInvalidObservation || hasConflict ? nil : candidate
        let selectedSystem = rawSystem ?? usableCandidate
        systemPower = selectedSystem
        systemPowerSource = rawSystem != nil ? .measured : (usableCandidate != nil ? .powerBalance : .unavailable)

        var input: DisplayedPowerMeasurement?
        var battery: DisplayedPowerMeasurement?
        var reason: PowerFlowFallbackReason?
        var adjustment: PowerFlowInputAdjustment?
        if hasConflict {
            reason = .conflictingDirection
        } else if hasInvalidObservation {
            reason = .invalidBalance
        } else if let selectedSystem {
            let systemTicks = Self.ticks(selectedSystem.watts)
            let ratingTicks = Self.adapterRatingTicks(snapshot)
            switch observedState {
            case .discharging:
                // The battery is the only source; use the same anchor at both ends.
                battery = .init(watts: selectedSystem.watts, isApproximate: true)
            case .holding, .directPower:
                if observation.direction == .calm {
                    if let ratingTicks, systemTicks > ratingTicks {
                        input = Self.reading(ratingTicks / 10, isApproximate: true)
                        battery = Self.reading((systemTicks - ratingTicks) / 10, isApproximate: true)
                        adjustment = .limitedToAdapterRating
                        // This is a display-only residual, not a new battery
                        // measurement or a change to the diagnostic evidence.
                        displayState = .underpowered
                        if input == nil || battery == nil { reason = .invalidBalance }
                    } else {
                        input = .init(watts: selectedSystem.watts, isApproximate: true)
                    }
                } else {
                    reason = .missingMeasurement
                }
            case .charging:
                if let observedBattery {
                    // Input = system + charge, kept within the adapter rating.
                    var chargeTicks = Self.ticks(observedBattery.watts)
                    if let ratingTicks, systemTicks + chargeTicks > ratingTicks {
                        chargeTicks = ratingTicks - systemTicks
                        adjustment = .limitedToAdapterRating
                    }
                    if chargeTicks > 0 {
                        input = Self.reading((systemTicks + chargeTicks) / 10, isApproximate: true)
                        battery = adjustment == nil
                            ? observedBattery
                            : Self.reading(chargeTicks / 10, isApproximate: true)
                    } else {
                        // The system anchor alone already exceeds the rating.
                        reason = .invalidBalance
                    }
                } else {
                    reason = .missingMeasurement
                }
            case .underpowered:
                if let observedBattery {
                    // Input = system − discharge, kept between 0 W and the
                    // adapter rating.
                    var dischargeTicks = Self.ticks(observedBattery.watts)
                    if dischargeTicks > systemTicks {
                        dischargeTicks = systemTicks
                        adjustment = .raisedToZero
                    } else if let ratingTicks, systemTicks - dischargeTicks > ratingTicks {
                        dischargeTicks = systemTicks - ratingTicks
                        adjustment = .limitedToAdapterRating
                    }
                    if dischargeTicks > 0 {
                        input = Self.reading((systemTicks - dischargeTicks) / 10, isApproximate: true)
                        battery = adjustment == nil
                            ? observedBattery
                            : Self.reading(dischargeTicks / 10, isApproximate: true)
                    } else {
                        // A 0 W system anchor cannot carry a battery-assist route.
                        reason = .invalidBalance
                    }
                } else {
                    reason = .missingMeasurement
                }
            case .unknown:
                reason = .conflictingDirection
            }
        } else {
            reason = unroundedCandidate.map { !$0.isFinite || $0 < 0 } == true
                ? .invalidBalance : .missingMeasurement
        }

        // Incomplete evidence must not put unrelated raw values back on the
        // diagram. Keep the known system value and an unavailable source.
        state = displayState
        fallbackReason = reason
        hasBalancedFlow = reason == nil
        inputPower = reason == nil ? input : nil
        batteryPower = reason == nil ? battery : nil
        inputAdjustment = reason == nil ? adjustment : nil
    }

    private static func ticks(_ watts: Double) -> Double {
        (watts * 10).rounded(.toNearestOrEven)
    }

    private static func adapterRatingTicks(_ snapshot: TelemetrySnapshot) -> Double? {
        guard snapshot.externalConnected,
              let ratingW = snapshot.adapterMaxPowerW,
              ratingW.isFinite, ratingW > 0 else {
            return nil
        }
        return ticks(ratingW)
    }

    private static func reading(
        _ watts: Double?,
        isApproximate: Bool = false
    ) -> DisplayedPowerMeasurement? {
        guard let watts, watts.isFinite, watts >= 0,
              (watts * 10).isFinite else {
            return nil
        }
        let rounded = (watts * 10).rounded(.toNearestOrEven) / 10
        return DisplayedPowerMeasurement(
            watts: rounded == 0 ? 0 : rounded,
            isApproximate: isApproximate
        )
    }

    private static func resolveState(
        snapshot: TelemetrySnapshot,
        batteryFlow: BatteryFlowObservation
    ) -> PowerFlowDiagramState {
        if !snapshot.externalConnected {
            return .discharging
        }

        switch batteryFlow.direction {
        case .discharging:
            return .underpowered
        case .charging:
            return .charging
        case .conflicted:
            return .unknown
        case .calm:
            return snapshot.externalPowerState == .holding
                ? .holding
                : .directPower
        case .unavailable:
            return .directPower
        }
    }

    /// In captured samples, SMC battery power reflected a direction change
    /// while the separately sampled registry current stayed on the old
    /// direction for more than 15 seconds. That current cannot veto the SMC
    /// route; this does not imply that the SMC values share one update time.
    /// Diagnostics keep the combined evidence.
    private static func smcBatteryDirection(
        _ snapshot: TelemetrySnapshot
    ) -> BatteryFlowEvidence? {
        guard snapshot.powerMeasurementSetSource == .smc,
              let batteryPowerW = snapshot.batteryPowerW,
              batteryPowerW.isFinite else {
            return nil
        }
        if batteryPowerW > batteryFlowThresholdW {
            return .discharging
        }
        if batteryPowerW < -batteryFlowThresholdW {
            return .charging
        }
        return .calm
    }

    /// Matches the display thresholds used for the combined battery evidence.
    private static let batteryFlowThresholdW = 0.35

    private static func observeBatteryFlow(
        _ snapshot: TelemetrySnapshot,
        smcDirection: BatteryFlowEvidence?
    ) -> BatteryFlowObservation {
        if let smcDirection, let batteryPowerW = snapshot.batteryPowerW {
            switch smcDirection {
            case .discharging:
                return BatteryFlowObservation(direction: .discharging, powerW: batteryPowerW, source: .measured)
            case .charging:
                return BatteryFlowObservation(direction: .charging, powerW: -batteryPowerW, source: .measured)
            case .calm, .conflicted, .unavailable:
                // On battery, a calm reading still routes the system anchor
                // through the battery, as in `observeBatteryOnlyFlow`.
                return snapshot.externalConnected
                    ? BatteryFlowObservation(direction: .calm, powerW: nil, source: .measured)
                    : BatteryFlowObservation(direction: .discharging, powerW: nil, source: .unavailable)
            }
        }

        if !snapshot.externalConnected {
            return observeBatteryOnlyFlow(snapshot)
        }

        // Keep diagnostics conservative when independently cached battery
        // current disagrees. For the diagram only, a complete PowerTelemetry
        // set that still satisfies input + battery = system is stronger route
        // evidence than that conflicting current sample. SMC sets are handled
        // above by their battery-power sign.
        if snapshot.batteryFlowEvidence == .conflicted,
           let coherentPowerSetFlow = observeCoherentPowerSet(snapshot) {
            return coherentPowerSetFlow
        }

        switch snapshot.batteryFlowEvidence {
        case .discharging:
            if let measuredBatteryDischargeW =
                snapshot.measuredBatteryDischargeW {
                return BatteryFlowObservation(
                    direction: .discharging,
                    powerW: measuredBatteryDischargeW,
                    source: isDirectDischargePower(
                        measuredBatteryDischargeW,
                        snapshot: snapshot
                    ) ? .measured : .currentAndVoltage
                )
            }
            return BatteryFlowObservation(
                direction: .discharging,
                powerW: nil,
                source: .unavailable
            )
        case .charging:
            if let measuredBatteryChargeW = snapshot.measuredBatteryChargeW {
                return BatteryFlowObservation(
                    direction: .charging,
                    powerW: measuredBatteryChargeW,
                    source: isDirectChargePower(
                        measuredBatteryChargeW,
                        snapshot: snapshot
                    ) ? .measured : .currentAndVoltage
                )
            }

            // `isCharging` is a fallback only when both direct battery-flow
            // measurements are unavailable. Preserve the long-standing 0.3 W
            // guard before turning an input/load residual into a charge route.
            if snapshot.batteryPowerW == nil,
               snapshot.batteryCurrentA == nil,
               let inferredChargePower = positiveDifference(
                   snapshot.adapterInputPowerW,
                   snapshot.systemLoadW
               ),
               inferredChargePower > 0.3 {
                return BatteryFlowObservation(
                    direction: .charging,
                    powerW: inferredChargePower,
                    source: .inputLoadDifference
                )
            }

            if snapshot.batteryPowerW != nil
                || snapshot.batteryCurrentA != nil {
                return BatteryFlowObservation(
                    direction: .charging,
                    powerW: nil,
                    source: .unavailable
                )
            }

            return BatteryFlowObservation(
                direction: .unavailable,
                powerW: nil,
                source: .unavailable
            )
        case .calm:
            return BatteryFlowObservation(
                direction: .calm,
                powerW: nil,
                source: .measured
            )
        case .conflicted:
            return BatteryFlowObservation(
                direction: .conflicted,
                powerW: nil,
                source: .unavailable
            )
        case .unavailable:
            if let inferredBatteryAssist = positiveDifference(
                snapshot.systemLoadW,
                snapshot.adapterInputPowerW
            ), inferredBatteryAssist > 0.35 {
                return BatteryFlowObservation(
                    direction: .discharging,
                    powerW: inferredBatteryAssist,
                    source: .inputLoadDifference
                )
            }
            return BatteryFlowObservation(
                direction: .unavailable,
                powerW: nil,
                source: .unavailable
            )
        }
    }

    private static func observeCoherentPowerSet(
        _ snapshot: TelemetrySnapshot
    ) -> BatteryFlowObservation? {
        guard snapshot.powerMeasurementSetSource != nil,
              snapshot.batteryPowerSource == .directTelemetry,
              let batteryPowerW = snapshot.batteryPowerW,
              let inputPowerW = snapshot.adapterInputPowerW,
              let systemLoadW = snapshot.systemLoadW,
              inputPowerW.isFinite, inputPowerW >= 0,
              abs(batteryPowerW) > 0.35,
              powerValuesAreCoherent(
                  inputPowerW + batteryPowerW,
                  systemLoadW
              ) else {
            return nil
        }

        return BatteryFlowObservation(
            direction: batteryPowerW > 0 ? .discharging : .charging,
            powerW: abs(batteryPowerW),
            source: .measured
        )
    }

    private static func observeBatteryOnlyFlow(
        _ snapshot: TelemetrySnapshot
    ) -> BatteryFlowObservation {
        if let measuredBatteryDischargeW = snapshot.measuredBatteryDischargeW {
            return BatteryFlowObservation(
                direction: .discharging,
                powerW: measuredBatteryDischargeW,
                source: isDirectDischargePower(
                    measuredBatteryDischargeW,
                    snapshot: snapshot
                ) ? .measured : .currentAndVoltage
            )
        }

        return BatteryFlowObservation(
            direction: .discharging,
            powerW: nil,
            source: .unavailable
        )
    }

    private static func isDirectDischargePower(
        _ powerW: Double,
        snapshot: TelemetrySnapshot
    ) -> Bool {
        guard !snapshot.batteryPowerIsDerived else {
            return false
        }
        return snapshot.batteryPowerW.map {
            isApproximatelyEqual(powerW, $0)
        } ?? false
    }

    private static func isDirectChargePower(
        _ powerW: Double,
        snapshot: TelemetrySnapshot
    ) -> Bool {
        guard !snapshot.batteryPowerIsDerived else {
            return false
        }
        return snapshot.batteryPowerW.map {
            isApproximatelyEqual(powerW, -$0)
        } ?? false
    }

    private static func positiveDifference(
        _ minuend: Double?,
        _ subtrahend: Double?
    ) -> Double? {
        guard let minuend, let subtrahend else {
            return nil
        }
        return max(minuend - subtrahend, 0)
    }

    private static func powerValuesAreCoherent(
        _ lhs: Double,
        _ rhs: Double
    ) -> Bool {
        guard lhs.isFinite, rhs.isFinite, lhs >= 0, rhs >= 0 else {
            return false
        }
        let comparisonMagnitudeW = max(abs(lhs), abs(rhs))
        let allowedDifferenceW = max(
            1,
            comparisonMagnitudeW * 0.05
        )
        return abs(lhs - rhs) <= allowedDifferenceW
    }

    private static func isApproximatelyEqual(
        _ lhs: Double,
        _ rhs: Double
    ) -> Bool {
        abs(lhs - rhs) <= 0.0001
    }
}
