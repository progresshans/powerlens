import Foundation

enum PowerFlowDiagramState: Equatable, Sendable {
    case holding
    case directPower
    case charging
    case underpowered
    case discharging
    case unknown

    var localizedTitle: String {
        switch self {
        case .holding:
            L10n.text("ui.flow.holding")
        case .directPower:
            L10n.text("ui.flow.directPower")
        case .charging:
            L10n.text("ui.flow.charging")
        case .underpowered:
            L10n.text("ui.flow.batteryAssist")
        case .discharging:
            L10n.text("ui.flow.batteryOnly")
        case .unknown:
            L10n.text("ui.flow.unknown")
        }
    }

    var tintRole: PowerFlowEndpointRole {
        switch self {
        case .holding, .directPower:
            .input
        case .charging:
            .charge
        case .underpowered, .discharging:
            .battery
        case .unknown:
            .input
        }
    }
}

enum PowerFlowEndpointRole: Equatable, Sendable {
    case input
    case system
    case battery
    case charge
}

struct PowerFlowEndpointModel: Equatable, Sendable {
    let title: String
    let value: String
    let systemImage: String
    let role: PowerFlowEndpointRole

    var identity: String {
        "\(title)|\(systemImage)"
    }
}

struct PowerFlowRouteModel: Equatable, Sendable {
    let source: PowerFlowEndpointModel
    let target: PowerFlowEndpointModel
    let role: PowerFlowEndpointRole
}

struct PowerFlowPresentationModel: Equatable, Sendable {
    private enum FlowValueSource {
        case measured
        case currentAndVoltage
        case inputLoadDifference
        case unavailable

        var isDerived: Bool {
            switch self {
            case .currentAndVoltage, .inputLoadDifference:
                true
            case .measured, .unavailable:
                false
            }
        }
    }

    private struct BatteryFlowObservation {
        let direction: BatteryFlowEvidence
        let powerW: Double?
        let source: FlowValueSource
    }

    let state: PowerFlowDiagramState
    let statusTitle: String
    let showsIndependentReadingsNotice: Bool
    let routes: [PowerFlowRouteModel]

    init(snapshot: TelemetrySnapshot) {
        let batteryFlow = Self.observeBatteryFlow(snapshot)
        let state = Self.resolveState(
            snapshot: snapshot,
            batteryFlow: batteryFlow
        )
        let routes = Self.routes(
            state: state,
            snapshot: snapshot,
            batteryFlow: batteryFlow
        )
        let showsIndependentReadingsNotice =
            state == .unknown
                || batteryFlow.source.isDerived
                || (
                    (state == .charging || state == .underpowered
                        || state == .discharging)
                        && batteryFlow.powerW == nil
                )
                || snapshot.hasConflictingBatteryPowerMeasurements
                || snapshot.hasConflictingDischargePowerBalance
                || Self.hasPowerBalanceMismatch(
                    state: state,
                    snapshot: snapshot,
                    batteryPowerW: batteryFlow.powerW
                )

        self.state = state
        // The flow badge describes the latest physical route only. Managed
        // charging policy is presented separately in the stable status model.
        self.statusTitle = state.localizedTitle
        self.showsIndependentReadingsNotice = showsIndependentReadingsNotice
        self.routes = routes
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

    private static func observeBatteryFlow(
        _ snapshot: TelemetrySnapshot
    ) -> BatteryFlowObservation {
        if !snapshot.externalConnected {
            return observeBatteryOnlyFlow(snapshot)
        }

        // Keep diagnostics conservative when independently cached battery
        // current disagrees. For the diagram only, a complete same-provider
        // power set that still satisfies input + battery = system is stronger
        // route evidence than that conflicting current sample.
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

    private static func routes(
        state: PowerFlowDiagramState,
        snapshot: TelemetrySnapshot,
        batteryFlow: BatteryFlowObservation
    ) -> [PowerFlowRouteModel] {
        switch state {
        case .underpowered:
            return [
                PowerFlowRouteModel(
                    source: inputEndpoint(snapshot),
                    target: systemEndpoint(snapshot),
                    role: .input
                ),
                PowerFlowRouteModel(
                    source: batteryEndpoint(
                        value: batteryFlow.powerW,
                        source: batteryFlow.source
                    ),
                    target: systemEndpoint(snapshot),
                    role: .battery
                ),
            ]
        case .discharging:
            return [
                PowerFlowRouteModel(
                    source: batteryEndpoint(
                        value: batteryFlow.powerW,
                        source: batteryFlow.source
                    ),
                    target: systemEndpoint(snapshot),
                    role: .battery
                )
            ]
        case .charging:
            return [
                PowerFlowRouteModel(
                    source: inputEndpoint(snapshot),
                    target: systemEndpoint(snapshot),
                    role: .input
                ),
                PowerFlowRouteModel(
                    source: inputEndpoint(snapshot),
                    target: batteryChargeEndpoint(
                        value: batteryFlow.powerW,
                        source: batteryFlow.source
                    ),
                    role: .charge
                ),
            ]
        case .holding, .directPower, .unknown:
            return [
                PowerFlowRouteModel(
                    source: inputEndpoint(snapshot),
                    target: systemEndpoint(snapshot),
                    role: .input
                )
            ]
        }
    }

    private static func inputEndpoint(
        _ snapshot: TelemetrySnapshot
    ) -> PowerFlowEndpointModel {
        // These endpoint values deliberately stay aligned with Power Details.
        // The sensors update independently, so the diagram must not rewrite a
        // measured adapter value merely to make the visible totals add up.
        PowerFlowEndpointModel(
            title: L10n.text("ui.metric.input"),
            value: snapshot.adapterInputPowerW.map(Formatters.power)
                ?? L10n.text("common.none"),
            systemImage: "powerplug.fill",
            role: .input
        )
    }

    private static func systemEndpoint(_ snapshot: TelemetrySnapshot) -> PowerFlowEndpointModel {
        PowerFlowEndpointModel(
            title: L10n.text("ui.metric.systemLoad"),
            value: snapshot.systemLoadW.map(Formatters.power) ?? L10n.text("common.none"),
            systemImage: "waveform.path.ecg",
            role: .system
        )
    }

    private static func batteryEndpoint(
        value: Double?,
        source: FlowValueSource
    ) -> PowerFlowEndpointModel {
        PowerFlowEndpointModel(
            title: L10n.text("ui.metric.battery"),
            value: formattedFlowValue(value, source: source),
            systemImage: "battery.100",
            role: .battery
        )
    }

    private static func batteryChargeEndpoint(
        value: Double?,
        source: FlowValueSource
    ) -> PowerFlowEndpointModel {
        PowerFlowEndpointModel(
            title: L10n.text("ui.flow.charging"),
            value: formattedFlowValue(value, source: source),
            systemImage: "battery.100",
            role: .charge
        )
    }

    private static func formattedFlowValue(
        _ value: Double?,
        source: FlowValueSource
    ) -> String {
        guard let value else {
            return L10n.text("common.none")
        }
        let formatted = Formatters.power(value)
        return source.isDerived ? "≈\(formatted)" : formatted
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

    private static func hasPowerBalanceMismatch(
        state: PowerFlowDiagramState,
        snapshot: TelemetrySnapshot,
        batteryPowerW: Double?
    ) -> Bool {
        let observedPowerW: Double
        let representedPowerW: Double

        switch state {
        case .underpowered:
            guard let inputPowerW = snapshot.adapterInputPowerW,
                  let batteryPowerW,
                  let systemLoadW = snapshot.systemLoadW else {
                return false
            }
            observedPowerW = inputPowerW + batteryPowerW
            representedPowerW = systemLoadW
        case .charging:
            guard let inputPowerW = snapshot.adapterInputPowerW,
                  let batteryPowerW,
                  let systemLoadW = snapshot.systemLoadW else {
                return false
            }
            observedPowerW = inputPowerW
            representedPowerW = systemLoadW + batteryPowerW
        case .holding, .directPower, .unknown:
            guard let inputPowerW = snapshot.adapterInputPowerW,
                  let systemLoadW = snapshot.systemLoadW else {
                return false
            }
            observedPowerW = inputPowerW
            representedPowerW = systemLoadW
        case .discharging:
            guard let batteryPowerW,
                  let systemLoadW = snapshot.systemLoadW else {
                return false
            }
            observedPowerW = batteryPowerW
            representedPowerW = systemLoadW
        }

        let comparisonMagnitudeW = max(
            abs(observedPowerW),
            abs(representedPowerW)
        )
        let allowedDifferenceW = max(
            1,
            comparisonMagnitudeW * 0.1
        )
        return abs(observedPowerW - representedPowerW) > allowedDifferenceW
    }

    private static func powerValuesAreCoherent(
        _ lhs: Double,
        _ rhs: Double
    ) -> Bool {
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
