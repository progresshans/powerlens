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
    let tooltip: String
    let systemImage: String
    let role: PowerFlowEndpointRole
    /// The displayed watts behind `value`, for sizing the drawn strands.
    var watts: Double?

    var identity: String {
        "\(title)|\(systemImage)"
    }
}

struct PowerFlowRouteModel: Equatable, Sendable {
    let source: PowerFlowEndpointModel
    let target: PowerFlowEndpointModel
    let role: PowerFlowEndpointRole
}

enum PowerFlowConnectionStyle: Equatable, Sendable {
    case solid
    case hidden
}

/// Which routes the power flow shows and the value on each end. The popover
/// and Dashboard both draw from this model through `PowerFlowGraph`, so the
/// flow tests cover what is on screen.
struct PowerFlowPresentationModel: Equatable, Sendable {
    let state: PowerFlowDiagramState
    let statusTitle: String
    let connectionStyle: PowerFlowConnectionStyle
    let routes: [PowerFlowRouteModel]

    var showsConnections: Bool {
        connectionStyle != .hidden
    }

    init(snapshot: TelemetrySnapshot) {
        let readings = PowerFlowReadings(snapshot: snapshot)
        // A connection requires a complete, balanced set of displayed values.
        state = readings.hasBalancedFlow ? readings.state : .unknown
        connectionStyle = readings.hasBalancedFlow ? .solid : .hidden
        statusTitle = state.localizedTitle
        routes = Self.routes(
            readings,
            tooltip: PowerFlowTooltip.text(snapshot: snapshot, readings: readings)
        )
    }

    private static func routes(
        _ readings: PowerFlowReadings,
        tooltip: String
    ) -> [PowerFlowRouteModel] {
        let system = endpoint(
            titleKey: "ui.metric.systemLoad", power: readings.systemPower,
            tooltip: tooltip, systemImage: "waveform.path.ecg", role: .system
        )
        guard readings.hasBalancedFlow else {
            let sourceRole: PowerFlowEndpointRole = readings.isExternalPower ? .input : .battery
            let source = endpoint(
                titleKey: readings.isExternalPower ? "ui.metric.input" : "ui.metric.battery",
                power: nil,
                tooltip: tooltip,
                systemImage: readings.isExternalPower ? "powerplug.fill" : "battery.100",
                role: sourceRole
            )
            return [PowerFlowRouteModel(source: source, target: system, role: sourceRole)]
        }
        let input = endpoint(
            titleKey: "ui.metric.input", power: readings.inputPower,
            tooltip: tooltip, systemImage: "powerplug.fill", role: .input
        )
        let battery = endpoint(
            titleKey: readings.state == .charging ? "ui.flow.charging" : "ui.metric.battery",
            power: readings.batteryPower, tooltip: tooltip, systemImage: "battery.100",
            role: readings.state == .charging ? .charge : .battery
        )

        switch readings.state {
        case .underpowered:
            return [
                PowerFlowRouteModel(source: input, target: system, role: .input),
                PowerFlowRouteModel(source: battery, target: system, role: .battery),
            ]
        case .discharging:
            return [PowerFlowRouteModel(source: battery, target: system, role: .battery)]
        case .charging:
            return [
                PowerFlowRouteModel(source: input, target: system, role: .input),
                PowerFlowRouteModel(source: input, target: battery, role: .charge),
            ]
        case .holding, .directPower, .unknown:
            return [PowerFlowRouteModel(source: input, target: system, role: .input)]
        }
    }

    private static func endpoint(
        titleKey: String,
        power: DisplayedPowerMeasurement?,
        tooltip: String,
        systemImage: String,
        role: PowerFlowEndpointRole
    ) -> PowerFlowEndpointModel {
        PowerFlowEndpointModel(
            title: L10n.text(titleKey),
            value: power?.formatted ?? L10n.text("common.none"),
            tooltip: tooltip,
            systemImage: systemImage,
            role: role,
            watts: power?.watts
        )
    }
}
