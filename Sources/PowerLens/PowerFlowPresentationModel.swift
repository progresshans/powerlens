import Foundation

enum PowerFlowDiagramState: Equatable, Sendable {
    case holding
    case directPower
    case charging
    case underpowered
    case discharging
    case unknown

}

enum PowerFlowEndpointRole: Equatable, Sendable {
    case input
    case system
    case battery
    case charge
}

struct PowerFlowEndpointModel: Equatable, Sendable {
    let role: PowerFlowEndpointRole
    let watts: Double?
    var value: String { watts.map(Formatters.power) ?? L10n.text("common.none") }

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
    let connectionStyle: PowerFlowConnectionStyle
    let routes: [PowerFlowRouteModel]

    var showsConnections: Bool {
        connectionStyle != .hidden
    }

    init(snapshot: TelemetrySnapshot) {
        self.init(snapshot: snapshot, readings: PowerFlowReadings(snapshot: snapshot))
    }

    init(snapshot: TelemetrySnapshot, readings: PowerFlowReadings) {
        // A connection requires a complete, balanced set of displayed values.
        state = readings.hasBalancedFlow ? readings.state : .unknown
        connectionStyle = readings.hasBalancedFlow ? .solid : .hidden
        routes = Self.routes(readings)
    }

    private static func routes(_ readings: PowerFlowReadings) -> [PowerFlowRouteModel] {
        let system = endpoint(readings.systemPower, role: .system)
        guard readings.hasBalancedFlow else {
            let sourceRole: PowerFlowEndpointRole = readings.isExternalPower ? .input : .battery
            let source = endpoint(nil, role: sourceRole)
            return [PowerFlowRouteModel(source: source, target: system, role: sourceRole)]
        }
        let input = endpoint(readings.inputPower, role: .input)
        let battery = endpoint(readings.batteryPower, role: readings.state == .charging ? .charge : .battery)

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

    private static func endpoint(_ power: DisplayedPowerMeasurement?, role: PowerFlowEndpointRole) -> PowerFlowEndpointModel {
        PowerFlowEndpointModel(role: role, watts: power?.watts)
    }
}
