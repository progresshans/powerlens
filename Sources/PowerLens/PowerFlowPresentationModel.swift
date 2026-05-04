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
        let externalToSystemPower = snapshot.externalConnected ? min(inputPower, loadPower) : 0
        let chargePower = inputPower > 0 ? max(inputPower - externalToSystemPower, 0) : snapshot.batteryChargeInflowW
        let batteryAssist = max(loadPower - inputPower, 0)
        let state = Self.resolveState(
            snapshot: snapshot,
            batteryAssist: batteryAssist,
            chargePower: chargePower
        )
        let externalToBatteryPower = state == .charging ? max(chargePower, 0) : 0
        let batteryToSystemPower = Self.batteryToSystemPower(
            state: state,
            loadPower: loadPower,
            externalToSystemPower: externalToSystemPower
        )

        self.state = state
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

    private static func batteryToSystemPower(
        state: PowerFlowDiagramState,
        loadPower: Double,
        externalToSystemPower: Double
    ) -> Double {
        switch state {
        case .discharging:
            return loadPower
        case .underpowered:
            return max(loadPower - externalToSystemPower, 0)
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

    private static func inputEndpoint(_ snapshot: TelemetrySnapshot) -> PowerFlowEndpointModel {
        PowerFlowEndpointModel(
            title: L10n.text("ui.metric.input"),
            value: snapshot.adapterInputPowerW.map(Formatters.power) ?? L10n.text("common.none"),
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
