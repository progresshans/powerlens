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
    let state: PowerFlowDiagramState
    let statusTitle: String
    let inputPower: Double
    let loadPower: Double
    let chargePower: Double
    let batteryAssist: Double
    let externalToSystemPower: Double
    let externalToBatteryPower: Double
    let batteryToSystemPower: Double
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
            ? min(resolvedBatteryAssist, loadPower)
            : resolvedBatteryAssist
        let inferredChargePower = max(inputPower - loadPower, 0)
        let chargePower = Self.resolveChargePower(
            snapshot: snapshot,
            inferredChargePower: inferredChargePower
        )
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
        self.routes = Self.routes(
            state: state,
            snapshot: snapshot,
            loadPower: loadPower,
            batteryToSystemPower: batteryToSystemPower,
            externalToBatteryPower: externalToBatteryPower
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
    ) -> Double {
        switch snapshot.batteryFlowEvidence {
        case .discharging:
            if let measuredBatteryDischargeW =
                snapshot.measuredBatteryDischargeW {
                return measuredBatteryDischargeW
            }
            return inferredBatteryAssist
        case .unavailable:
            // Compatible telemetry has no direct battery-flow measurements,
            // so retain the input/load fallback.
            return inferredBatteryAssist
        case .charging, .calm, .conflicted:
            // Direct measurements take precedence over a non-atomic
            // input/load difference.
            return 0
        }
    }

    private static func resolveChargePower(
        snapshot: TelemetrySnapshot,
        inferredChargePower: Double
    ) -> Double {
        guard snapshot.batteryFlowEvidence == .charging else {
            return 0
        }

        if let measuredBatteryChargeW = snapshot.measuredBatteryChargeW {
            return measuredBatteryChargeW
        }
        return inferredChargePower
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
        loadPower: Double,
        batteryToSystemPower: Double,
        externalToBatteryPower: Double
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
                    source: batteryEndpoint(value: Formatters.power(batteryToSystemPower)),
                    target: systemEndpoint(snapshot),
                    role: .battery
                ),
            ]
        case .discharging:
            return [
                PowerFlowRouteModel(
                    source: batteryEndpoint(value: Formatters.power(loadPower)),
                    target: systemEndpoint(value: Formatters.power(loadPower)),
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
                    target: batteryChargeEndpoint(value: Formatters.power(externalToBatteryPower)),
                    role: .charge
                ),
            ]
        case .holding, .directPower:
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
        // Endpoint cards stay aligned with the raw dashboard metrics. The
        // battery-flow direction can be more trustworthy than a non-atomic
        // input/load pair, but we must not fabricate an exact adapter reading
        // merely to make those independently sampled values add up.
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

    private static func systemEndpoint(value: String) -> PowerFlowEndpointModel {
        PowerFlowEndpointModel(
            title: L10n.text("ui.metric.systemLoad"),
            value: value,
            systemImage: "waveform.path.ecg",
            role: .system
        )
    }

    private static func batteryEndpoint(value: String) -> PowerFlowEndpointModel {
        PowerFlowEndpointModel(
            title: L10n.text("ui.metric.battery"),
            value: value,
            systemImage: "battery.100",
            role: .battery
        )
    }

    private static func batteryChargeEndpoint(value: String) -> PowerFlowEndpointModel {
        PowerFlowEndpointModel(
            title: L10n.text("ui.flow.charging"),
            value: value,
            systemImage: "battery.100",
            role: .charge
        )
    }
}
