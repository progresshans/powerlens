import Foundation

/// The flow drawn by `PowerFlowRibbonDiagram`: sources on the left, the places
/// the power goes on the right, and one link per route sized by watts.
///
/// Built from `PowerFlowPresentationModel`, which decides the routes and the
/// value on each end; this type only lays them out as nodes and links.
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

    init(model: PowerFlowPresentationModel) {
        func endpoint(_ role: PowerFlowEndpointRole) -> Endpoint {
            switch role {
            case .input: .charger
            case .battery, .charge: .battery
            case .system: .mac
            }
        }
        func node(_ model: PowerFlowEndpointModel) -> Node {
            Node(endpoint: endpoint(model.role), watts: model.watts, value: model.value)
        }

        var sources: [Node] = []
        var destinations: [Node] = []
        for route in model.routes {
            let source = node(route.source)
            let target = node(route.target)
            if !sources.contains(where: { $0.endpoint == source.endpoint }) {
                sources.append(source)
            }
            if !destinations.contains(where: { $0.endpoint == target.endpoint }) {
                destinations.append(target)
            }
        }

        state = model.state
        self.sources = sources
        self.destinations = destinations
        // Unbalanced readings keep their known values but draw no routes.
        links = model.showsConnections ? model.routes.compactMap { route in
            // A split shares its source and a merge shares its target, so the
            // smaller end is the power carried by this route.
            guard let sourceWatts = route.source.watts, let targetWatts = route.target.watts else {
                return nil
            }
            let watts = min(sourceWatts, targetWatts)
            guard watts > 0 else {
                return nil
            }
            return Link(from: endpoint(route.source.role), to: endpoint(route.target.role), watts: watts)
        } : []
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
