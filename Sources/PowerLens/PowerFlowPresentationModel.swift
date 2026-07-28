import Foundation

enum PowerFlowDiagramState: Equatable, Sendable {
    case holding
    case directPower
    case charging
    case underpowered
    case discharging

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
    private struct FlowPowerEstimate {
        let value: Double
        let isEstimated: Bool
    }

    let state: PowerFlowDiagramState
    let statusTitle: String
    let inputPower: Double
    let loadPower: Double
    let chargePower: Double
    let batteryAssist: Double
    let externalToSystemPower: Double
    let externalToBatteryPower: Double
    let batteryToSystemPower: Double
    let usesEstimatedContributions: Bool
    let routes: [PowerFlowRouteModel]

    init(snapshot: TelemetrySnapshot) {
        let inputPower = max(snapshot.adapterInputPowerW ?? 0, 0)
        let loadPower = max(snapshot.systemLoadW ?? 0, 0)
        let inferredBatteryAssist = max(loadPower - inputPower, 0)
        let resolvedBatteryAssist = Self.resolveBatteryAssist(
            snapshot: snapshot,
            inferredBatteryAssist: inferredBatteryAssist
        )
        let batteryAssist = loadPower > 0
            ? min(resolvedBatteryAssist.value, loadPower)
            : resolvedBatteryAssist.value
        let batteryAssistIsEstimated =
            resolvedBatteryAssist.isEstimated
                || !Self.isApproximatelyEqual(
                    batteryAssist,
                    resolvedBatteryAssist.value
                )
        let inferredChargePower = max(inputPower - loadPower, 0)
        let resolvedChargePower = Self.resolveChargePower(
            snapshot: snapshot,
            inferredChargePower: inferredChargePower
        )
        let chargePower = resolvedChargePower.value
        let state = Self.resolveState(
            snapshot: snapshot,
            batteryAssist: batteryAssist,
            chargePower: chargePower
        )
        let externalToSystemPower: Double
        switch state {
        case .underpowered:
            externalToSystemPower = max(loadPower - batteryAssist, 0)
        case .discharging:
            externalToSystemPower = 0
        case .holding, .directPower, .charging:
            externalToSystemPower = snapshot.externalConnected ? loadPower : 0
        }
        let externalToBatteryPower = state == .charging ? max(chargePower, 0) : 0
        let batteryToSystemPower = Self.batteryToSystemPower(
            state: state,
            loadPower: loadPower,
            batteryAssist: batteryAssist
        )
        let diagramInputPower: Double?
        switch state {
        case .underpowered, .holding, .directPower:
            diagramInputPower = snapshot.systemLoadW == nil
                ? snapshot.adapterInputPowerW
                : externalToSystemPower
        case .charging:
            diagramInputPower = snapshot.systemLoadW == nil
                ? snapshot.adapterInputPowerW
                : externalToSystemPower + externalToBatteryPower
        case .discharging:
            diagramInputPower = nil
        }
        let inputContributionIsEstimated = Self.isEstimatedContribution(
            diagramInputPower,
            comparedWith: snapshot.adapterInputPowerW
        )
        let batteryContributionIsEstimated: Bool
        switch state {
        case .underpowered:
            batteryContributionIsEstimated = batteryAssistIsEstimated
        case .discharging:
            batteryContributionIsEstimated =
                snapshot.hasConflictingBatteryPowerMeasurements
                    || Self.isEstimatedContribution(
                        batteryToSystemPower,
                        comparedWith: snapshot.measuredBatteryDischargeW
                    )
        case .holding, .directPower, .charging:
            batteryContributionIsEstimated = false
        }
        let chargeContributionIsEstimated =
            state == .charging && resolvedChargePower.isEstimated
        let usesEstimatedContributions =
            inputContributionIsEstimated
                || batteryContributionIsEstimated
                || chargeContributionIsEstimated

        self.state = state
        // The flow badge describes the latest physical route only. Managed
        // charging policy is presented separately in the stable status model.
        self.statusTitle = state.localizedTitle
        self.inputPower = inputPower
        self.loadPower = loadPower
        self.chargePower = chargePower
        self.batteryAssist = batteryAssist
        self.externalToSystemPower = externalToSystemPower
        self.externalToBatteryPower = externalToBatteryPower
        self.batteryToSystemPower = batteryToSystemPower
        self.usesEstimatedContributions = usesEstimatedContributions
        self.routes = Self.routes(
            state: state,
            snapshot: snapshot,
            diagramInputPower: diagramInputPower,
            inputContributionIsEstimated: inputContributionIsEstimated,
            batteryToSystemPower: batteryToSystemPower,
            batteryContributionIsEstimated:
                batteryContributionIsEstimated,
            externalToBatteryPower: externalToBatteryPower,
            chargeContributionIsEstimated: chargeContributionIsEstimated
        )
    }

    private static func resolveState(
        snapshot: TelemetrySnapshot,
        batteryAssist: Double,
        chargePower: Double
    ) -> PowerFlowDiagramState {
        if !snapshot.externalConnected {
            return .discharging
        }

        if batteryAssist > 0.35 {
            return .underpowered
        }

        if snapshot.isBatteryChargingForDisplay && chargePower > 0.3 {
            return .charging
        }

        if snapshot.externalPowerState == .holding {
            return .holding
        }

        return .directPower
    }

    private static func resolveBatteryAssist(
        snapshot: TelemetrySnapshot,
        inferredBatteryAssist: Double
    ) -> FlowPowerEstimate {
        switch snapshot.batteryFlowEvidence {
        case .discharging:
            if snapshot.hasConflictingBatteryPowerMeasurements
                || snapshot.hasConflictingDischargePowerBalance {
                return FlowPowerEstimate(
                    value: inferredBatteryAssist,
                    isEstimated: true
                )
            }
            if let measuredBatteryDischargeW =
                snapshot.measuredBatteryDischargeW {
                return FlowPowerEstimate(
                    value: measuredBatteryDischargeW,
                    isEstimated: false
                )
            }
            return FlowPowerEstimate(
                value: inferredBatteryAssist,
                isEstimated: true
            )
        case .unavailable:
            // Compatible telemetry has no direct battery-flow measurements,
            // so retain the input/load fallback.
            return FlowPowerEstimate(
                value: inferredBatteryAssist,
                isEstimated: true
            )
        case .charging, .calm, .conflicted:
            // Direct measurements take precedence over a non-atomic
            // input/load difference.
            return FlowPowerEstimate(
                value: 0,
                isEstimated: snapshot.batteryFlowEvidence == .conflicted
            )
        }
    }

    private static func resolveChargePower(
        snapshot: TelemetrySnapshot,
        inferredChargePower: Double
    ) -> FlowPowerEstimate {
        guard snapshot.batteryFlowEvidence == .charging else {
            return FlowPowerEstimate(value: 0, isEstimated: false)
        }

        if snapshot.hasConflictingBatteryPowerMeasurements {
            return FlowPowerEstimate(
                value: inferredChargePower,
                isEstimated: true
            )
        }

        if let measuredBatteryChargeW = snapshot.measuredBatteryChargeW {
            return FlowPowerEstimate(
                value: measuredBatteryChargeW,
                isEstimated: false
            )
        }
        return FlowPowerEstimate(
            value: inferredChargePower,
            isEstimated: true
        )
    }

    private static func batteryToSystemPower(
        state: PowerFlowDiagramState,
        loadPower: Double,
        batteryAssist: Double
    ) -> Double {
        switch state {
        case .discharging:
            return loadPower
        case .underpowered:
            return batteryAssist
        case .holding, .directPower, .charging:
            return 0
        }
    }

    private static func routes(
        state: PowerFlowDiagramState,
        snapshot: TelemetrySnapshot,
        diagramInputPower: Double?,
        inputContributionIsEstimated: Bool,
        batteryToSystemPower: Double,
        batteryContributionIsEstimated: Bool,
        externalToBatteryPower: Double,
        chargeContributionIsEstimated: Bool
    ) -> [PowerFlowRouteModel] {
        switch state {
        case .underpowered:
            return [
                PowerFlowRouteModel(
                    source: inputEndpoint(
                        value: diagramInputPower,
                        isEstimated: inputContributionIsEstimated
                    ),
                    target: systemEndpoint(snapshot),
                    role: .input
                ),
                PowerFlowRouteModel(
                    source: batteryEndpoint(
                        value: batteryToSystemPower,
                        isEstimated: batteryContributionIsEstimated
                    ),
                    target: systemEndpoint(snapshot),
                    role: .battery
                ),
            ]
        case .discharging:
            return [
                PowerFlowRouteModel(
                    source: batteryEndpoint(
                        value: batteryToSystemPower,
                        isEstimated: batteryContributionIsEstimated
                    ),
                    target: systemEndpoint(snapshot),
                    role: .battery
                )
            ]
        case .charging:
            return [
                PowerFlowRouteModel(
                    source: inputEndpoint(
                        value: diagramInputPower,
                        isEstimated: inputContributionIsEstimated
                    ),
                    target: systemEndpoint(snapshot),
                    role: .input
                ),
                PowerFlowRouteModel(
                    source: inputEndpoint(
                        value: diagramInputPower,
                        isEstimated: inputContributionIsEstimated
                    ),
                    target: batteryChargeEndpoint(
                        value: externalToBatteryPower,
                        isEstimated: chargeContributionIsEstimated
                    ),
                    role: .charge
                ),
            ]
        case .holding, .directPower:
            return [
                PowerFlowRouteModel(
                    source: inputEndpoint(
                        value: diagramInputPower,
                        isEstimated: inputContributionIsEstimated
                    ),
                    target: systemEndpoint(snapshot),
                    role: .input
                )
            ]
        }
    }

    private static func inputEndpoint(
        value: Double?,
        isEstimated: Bool
    ) -> PowerFlowEndpointModel {
        PowerFlowEndpointModel(
            title: L10n.text("ui.metric.input"),
            value: formattedContribution(
                value,
                isEstimated: isEstimated
            ),
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
        value: Double,
        isEstimated: Bool
    ) -> PowerFlowEndpointModel {
        PowerFlowEndpointModel(
            title: L10n.text("ui.metric.battery"),
            value: formattedContribution(
                value,
                isEstimated: isEstimated
            ),
            systemImage: "battery.100",
            role: .battery
        )
    }

    private static func batteryChargeEndpoint(
        value: Double,
        isEstimated: Bool
    ) -> PowerFlowEndpointModel {
        PowerFlowEndpointModel(
            title: L10n.text("ui.flow.charging"),
            value: formattedContribution(
                value,
                isEstimated: isEstimated
            ),
            systemImage: "battery.100",
            role: .charge
        )
    }

    private static func formattedContribution(
        _ value: Double?,
        isEstimated: Bool
    ) -> String {
        guard let value else {
            return L10n.text("common.none")
        }
        let formatted = Formatters.power(value)
        return isEstimated ? "≈\(formatted)" : formatted
    }

    private static func isEstimatedContribution(
        _ contribution: Double?,
        comparedWith measurement: Double?
    ) -> Bool {
        guard let contribution else {
            return false
        }
        guard let measurement else {
            return true
        }
        return !isApproximatelyEqual(contribution, measurement)
    }

    private static func isApproximatelyEqual(
        _ lhs: Double,
        _ rhs: Double
    ) -> Bool {
        abs(lhs - rhs) <= 0.75
    }
}
