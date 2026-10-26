import Foundation

/// The flow drawn by `PowerFlowRibbonDiagram`: sources on the left, the places
/// the power goes on the right, and one link per route sized by watts.
///
/// Values come from `PowerFlowReadings`, so the displayed numbers balance the
/// same way they always have; this type only decides what to draw.
struct PowerFlowGraph: Equatable, Sendable {
    enum Endpoint: Hashable, Sendable {
        case charger
        case battery
        case mac
    }

    struct Node: Equatable, Sendable {
        let endpoint: Endpoint
        let watts: Double?
        let value: String
    }

    struct Link: Equatable, Sendable {
        let from: Endpoint
        let to: Endpoint
        let watts: Double
    }

    /// Which routes are drawn, ignoring the watts on them.
    struct Structure: Equatable, Sendable {
        let state: PowerFlowDiagramState
        let sources: [Endpoint]
        let destinations: [Endpoint]
    }

    let state: PowerFlowDiagramState
    let sources: [Node]
    let destinations: [Node]
    let links: [Link]

    var structure: Structure {
        Structure(state: state, sources: sources.map(\.endpoint), destinations: destinations.map(\.endpoint))
    }

    init(state: PowerFlowDiagramState, sources: [Node], destinations: [Node], links: [Link]) {
        self.state = state
        self.sources = sources
        self.destinations = destinations
        self.links = links
    }

    init(readings: PowerFlowReadings) {
        let none = L10n.text("common.none")
        func node(_ endpoint: Endpoint, _ power: DisplayedPowerMeasurement?) -> Node {
            Node(endpoint: endpoint, watts: power?.watts, value: power?.formatted ?? none)
        }

        guard readings.hasBalancedFlow else {
            state = .unknown
            sources = [node(readings.isExternalPower ? .charger : .battery, nil)]
            destinations = [node(.mac, nil)]
            links = []
            return
        }

        state = readings.state
        let input = readings.inputPower
        let battery = readings.batteryPower
        let system = readings.systemPower

        switch readings.state {
        case .charging:
            sources = [node(.charger, input)]
            destinations = [node(.mac, system), node(.battery, battery)]
            links = [
                Self.link(.charger, .mac, system),
                Self.link(.charger, .battery, battery),
            ].compactMap { $0 }
        case .underpowered:
            sources = [node(.charger, input), node(.battery, battery)]
            destinations = [node(.mac, system)]
            links = [
                Self.link(.charger, .mac, input),
                Self.link(.battery, .mac, battery),
            ].compactMap { $0 }
        case .discharging:
            sources = [node(.battery, battery ?? system)]
            destinations = [node(.mac, system)]
            links = [Self.link(.battery, .mac, system ?? battery)].compactMap { $0 }
        case .holding, .directPower:
            // The battery only appears while power moves in or out of it.
            sources = [node(.charger, input ?? system)]
            destinations = [node(.mac, system)]
            links = [Self.link(.charger, .mac, system ?? input)].compactMap { $0 }
        case .unknown:
            sources = [node(readings.isExternalPower ? .charger : .battery, nil)]
            destinations = [node(.mac, nil)]
            links = []
        }
    }

    private static func link(_ from: Endpoint, _ to: Endpoint, _ power: DisplayedPowerMeasurement?) -> Link? {
        guard let watts = power?.watts, watts > 0 else {
            return nil
        }
        return Link(from: from, to: to, watts: watts)
    }
}

/// Where each label and ribbon sits for a given canvas size. Pure geometry so
/// the widths and anchors can be checked without rendering.
///
/// Ribbons are rounded strokes that start just past their source label and
/// end just before their destination label. Width grows with the square root
/// of watts, so a 40W flow reads heavier than a 5W one without becoming a slab.
struct PowerFlowRibbonLayout: Equatable, Sendable {
    struct Metrics: Equatable, Sendable {
        /// Label width assumed until the real one has been measured.
        let labelWidth: CGFloat
        /// Space between a label and the rounded end of its ribbon.
        let gap: CGFloat
        let minWidth: CGFloat
        let widthPerRootWatt: CGFloat
        let maxWidth: CGFloat

        static let compact = Metrics(labelWidth: 56, gap: 12, minWidth: 3, widthPerRootWatt: 0.9, maxWidth: 9)
        static let large = Metrics(labelWidth: 140, gap: 20, minWidth: 4, widthPerRootWatt: 1.4, maxWidth: 14)

        func width(for watts: Double) -> CGFloat {
            min(maxWidth, minWidth + CGFloat(max(0, watts)).squareRoot() * widthPerRootWatt)
        }
    }

    struct Ribbon: Equatable, Sendable, Identifiable {
        let from: PowerFlowGraph.Endpoint
        let to: PowerFlowGraph.Endpoint
        let start: CGPoint
        let end: CGPoint
        let width: CGFloat
        /// Nothing could be measured on this route yet. Drawn as a quiet
        /// dotted line.
        let isResting: Bool

        var id: String { "\(from)-\(to)" }
    }

    static let restingWidth: CGFloat = 2

    let sourceCenters: [CGFloat]
    let destinationCenters: [CGFloat]
    let ribbons: [Ribbon]

    init(
        graph: PowerFlowGraph,
        size: CGSize,
        metrics: Metrics,
        labelWidths: [PowerFlowGraph.Endpoint: CGFloat] = [:]
    ) {
        func centers(_ count: Int) -> [CGFloat] {
            count <= 1 ? [size.height / 2] : [size.height * 0.25, size.height * 0.75]
        }
        func labelWidth(_ endpoint: PowerFlowGraph.Endpoint) -> CGFloat {
            min(labelWidths[endpoint] ?? metrics.labelWidth, size.width * 0.38)
        }

        let sourceCenters = centers(graph.sources.count)
        let destinationCenters = centers(graph.destinations.count)
        self.sourceCenters = sourceCenters
        self.destinationCenters = destinationCenters

        func start(_ endpoint: PowerFlowGraph.Endpoint) -> CGPoint? {
            graph.sources.firstIndex { $0.endpoint == endpoint }.map {
                CGPoint(x: labelWidth(endpoint) + metrics.gap, y: sourceCenters[$0])
            }
        }
        func end(_ endpoint: PowerFlowGraph.Endpoint) -> CGPoint? {
            graph.destinations.firstIndex { $0.endpoint == endpoint }.map {
                CGPoint(x: size.width - labelWidth(endpoint) - metrics.gap, y: destinationCenters[$0])
            }
        }

        var ribbons = graph.links.compactMap { link -> Ribbon? in
            guard let start = start(link.from), let end = end(link.to) else {
                return nil
            }
            return Ribbon(from: link.from, to: link.to, start: start, end: end, width: metrics.width(for: link.watts), isResting: false)
        }

        if let source = graph.sources.first, let origin = start(source.endpoint) {
            for destination in graph.destinations
            where graph.state == .unknown && !ribbons.contains(where: { $0.to == destination.endpoint }) {
                guard let end = end(destination.endpoint) else {
                    continue
                }
                ribbons.append(Ribbon(
                    from: source.endpoint,
                    to: destination.endpoint,
                    start: origin,
                    end: end,
                    width: Self.restingWidth,
                    isResting: true
                ))
            }
        }
        self.ribbons = ribbons
    }
}
