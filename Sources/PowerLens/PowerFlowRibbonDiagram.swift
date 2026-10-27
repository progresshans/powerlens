import SwiftUI

/// Power flow drawn as soft, rounded strands: each starts just past its
/// source label, bends gently to its destination, and fades from the source
/// hue to the destination hue. Width follows watts, but softly.
struct PowerFlowRibbonDiagram: View {
    enum Style {
        case compact
        case large

        var metrics: PowerFlowRibbonLayout.Metrics {
            switch self {
            case .compact: .compact
            case .large: .large
            }
        }
    }

    let graph: PowerFlowGraph
    let style: Style
    var notes: [PowerFlowGraph.Endpoint: String] = [:]
    var batteryLevel: Double?
    var tooltip: String?

    @State private var labelWidths: [PowerFlowGraph.Endpoint: CGFloat] = [:]
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.flowLightIsActive) private var flowLightIsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The moving light runs only in a visible popover, and never when the
    /// person asked for less motion.
    private var showsFlowLight: Bool {
        flowLightIsActive && !reduceMotion
    }

    private var height: CGFloat {
        let rows = max(graph.sources.count, graph.destinations.count)
        switch style {
        case .compact: return rows > 1 ? 104 : 60
        case .large: return rows > 1 ? 200 : 120
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = PowerFlowRibbonLayout(
                graph: graph,
                size: proxy.size,
                metrics: style.metrics,
                labelWidths: labelWidths
            )

            ZStack(alignment: .topLeading) {
                // Strands glide only when the routes change, like a charger
                // being plugged in. New watts every refresh land without
                // animating: each animated frame redraws the whole window, and
                // a refresh every few seconds would keep it busy. A resize
                // follows the window's own motion so strands and labels stay
                // together.
                ZStack(alignment: .topLeading) {
                    ForEach(layout.ribbons) { ribbon in
                        RibbonStrand(
                            ribbon: ribbon,
                            canvas: proxy.size,
                            glowOpacity: colorScheme == .dark ? 0.38 : 0.22
                        )
                        .transition(.opacity)
                    }
                }
                // Gradients render on the GPU instead of being re-rasterized
                // on the CPU whenever anything nearby redraws.
                .drawingGroup()
                .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: graph.structure)

                if showsFlowLight {
                    FlowLights(ribbons: layout.ribbons.filter { !$0.isResting })
                }

                ForEach(Array(graph.sources.enumerated()), id: \.element.endpoint) { index, node in
                    measuredLabel(node, alignment: .leading)
                        .frame(width: proxy.size.width, alignment: .leading)
                        .position(x: proxy.size.width / 2, y: layout.sourceCenters[index])
                }

                ForEach(Array(graph.destinations.enumerated()), id: \.element.endpoint) { index, node in
                    measuredLabel(node, alignment: .trailing)
                        .frame(width: proxy.size.width, alignment: .trailing)
                        .position(x: proxy.size.width / 2, y: layout.destinationCenters[index])
                }
            }
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .modifier(OptionalTooltip(text: tooltip))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Reports the label's natural width so the strand can start right
    /// beside it.
    private func measuredLabel(_ node: PowerFlowGraph.Node, alignment: HorizontalAlignment) -> some View {
        endpointLabel(node, alignment: alignment)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                labelWidths[node.endpoint] = width
            }
    }

    @ViewBuilder
    private func endpointLabel(_ node: PowerFlowGraph.Node, alignment: HorizontalAlignment) -> some View {
        let isLarge = style == .large
        VStack(alignment: alignment, spacing: isLarge ? 4 : 1) {
            HStack(spacing: isLarge ? 6 : 4) {
                if alignment == .leading {
                    icon(for: node)
                    title(for: node)
                } else {
                    title(for: node)
                    icon(for: node)
                }
            }

            if isLarge {
                // The dashboard sets new readings without motion: in its large
                // window even a Core Animation roll tripled measured energy.
                Text(node.value)
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                // `.headline`, rolling to each new reading.
                RollingNumberText(node.value, size: 13, weight: .bold)
            }

            if isLarge, let note = notes[node.endpoint] {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }

    private func icon(for node: PowerFlowGraph.Node) -> some View {
        Image(systemName: symbol(for: node.endpoint))
            .font(.system(size: style == .large ? 13 : 11, weight: .semibold))
            .foregroundStyle(Self.tint(node.endpoint))
    }

    private func title(for node: PowerFlowGraph.Node) -> some View {
        Text(Self.title(node.endpoint))
            .font(style == .large ? .callout.weight(.medium) : .subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func symbol(for endpoint: PowerFlowGraph.Endpoint) -> String {
        switch endpoint {
        case .charger:
            "powerplug.fill"
        case .battery:
            BatterySymbol.name(level: batteryLevel, isCharging: graph.state == .charging)
        case .mac:
            "laptopcomputer"
        }
    }

    private var accessibilityText: String {
        let nodes = (graph.sources + graph.destinations)
            .map { "\(Self.title($0.endpoint)) \($0.value)" }
        return ([L10n.text("ui.section.flow")] + nodes).joined(separator: ", ")
    }

    static func title(_ endpoint: PowerFlowGraph.Endpoint) -> String {
        switch endpoint {
        case .charger: L10n.text("flow.node.charger")
        case .battery: L10n.text("flow.node.battery")
        case .mac: L10n.text("flow.node.mac")
        }
    }

    static func tint(_ endpoint: PowerFlowGraph.Endpoint) -> Color {
        switch endpoint {
        case .charger: LensPalette.charger
        case .battery: LensPalette.battery
        case .mac: LensPalette.mac
        }
    }

    /// A gentle S-curve: leaves the source level, eases across, and arrives
    /// level at the destination.
    nonisolated static func path(from start: CGPoint, to end: CGPoint) -> Path {
        let reach = max(12, (end.x - start.x) * 0.5)
        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + reach, y: start.y),
            control2: CGPoint(x: end.x - reach, y: end.y)
        )
        return path
    }
}

/// One strand: a soft halo underneath a crisp rounded stroke, or a dotted
/// line when the route is resting.
private struct RibbonStrand: View {
    let ribbon: PowerFlowRibbonLayout.Ribbon
    let canvas: CGSize
    let glowOpacity: Double

    var body: some View {
        let curve = FlowCurve(start: ribbon.start, end: ribbon.end)

        if ribbon.isResting {
            curve.stroke(
                Color.secondary.opacity(0.4),
                style: StrokeStyle(lineWidth: ribbon.width, lineCap: .round, dash: [0.1, ribbon.width * 3.5])
            )
        } else {
            let gradient = LinearGradient(
                colors: [PowerFlowRibbonDiagram.tint(ribbon.from), PowerFlowRibbonDiagram.tint(ribbon.to)],
                startPoint: unitPoint(ribbon.start),
                endPoint: unitPoint(ribbon.end)
            )
            // Two wide, faint passes make the halo. A real blur would be
            // re-rasterized on the CPU every time the flow updates.
            ZStack {
                curve
                    .stroke(gradient, style: StrokeStyle(lineWidth: ribbon.width * 2.6, lineCap: .round))
                    .opacity(glowOpacity * 0.45)
                curve
                    .stroke(gradient, style: StrokeStyle(lineWidth: ribbon.width * 1.7, lineCap: .round))
                    .opacity(glowOpacity * 0.7)
                curve
                    .stroke(gradient, style: StrokeStyle(lineWidth: ribbon.width, lineCap: .round))
            }
        }
    }

    private func unitPoint(_ point: CGPoint) -> UnitPoint {
        UnitPoint(
            x: canvas.width > 0 ? point.x / canvas.width : 0,
            y: canvas.height > 0 ? point.y / canvas.height : 0.5
        )
    }
}

/// Short glints travelling from source to destination. Core Animation runs
/// them in the render server, so the app does no work per frame.
private struct FlowLights: NSViewRepresentable {
    let ribbons: [PowerFlowRibbonLayout.Ribbon]

    func makeNSView(context: Context) -> FlowLightsView {
        FlowLightsView()
    }

    func updateNSView(_ view: FlowLightsView, context: Context) {
        view.update(ribbons: ribbons)
    }
}

/// Each glint is a few stroked copies of its strand's curve sharing one
/// moving head. Longer copies are fainter, so together they fade from tail to
/// head. Every glint runs on one clock, so a split leaves the charger together
/// and a merge reaches the Mac together.
final class FlowLightsView: NSView {
    private static let period: CFTimeInterval = 2.6
    /// Fraction of the curve each copy covers, with its opacity.
    private static let trails: [(length: Double, opacity: Float)] = [(0.26, 0.3), (0.17, 0.35), (0.09, 0.55)]
    private static let haloOpacity: Float = 0.22

    private struct Glint {
        /// Fades the whole glint in and out over each lap.
        let container: CALayer
        let halo: CAShapeLayer
        let cores: [CAShapeLayer]

        var strokes: [CAShapeLayer] { [halo] + cores }
    }

    private var glints: [String: Glint] = [:]

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        glints.values.flatMap(\.strokes).forEach { $0.contentsScale = scale }
    }

    func update(ribbons: [PowerFlowRibbonLayout.Ribbon]) {
        guard let host = layer else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let liveIDs = Set(ribbons.map(\.id))
        for (id, glint) in glints where !liveIDs.contains(id) {
            glint.container.removeFromSuperlayer()
            glints[id] = nil
        }

        for ribbon in ribbons {
            let path = PowerFlowRibbonDiagram.path(from: ribbon.start, to: ribbon.end).cgPath
            let coreWidth = max(1.5, ribbon.width * 0.42)
            if let glint = glints[ribbon.id] {
                glint.strokes.forEach { $0.path = path }
                glint.halo.lineWidth = ribbon.width * 1.3
                glint.cores.forEach { $0.lineWidth = coreWidth }
                continue
            }

            let container = CALayer()
            container.add(Self.fadeAnimation(), forKey: "fade")
            let halo = makeStroke(path: path, width: ribbon.width * 1.3, opacity: Self.haloOpacity, length: Self.trails[0].length)
            let cores = Self.trails.map {
                makeStroke(path: path, width: coreWidth, opacity: $0.opacity, length: $0.length)
            }
            ([halo] + cores).forEach(container.addSublayer)
            host.addSublayer(container)
            glints[ribbon.id] = Glint(container: container, halo: halo, cores: cores)
        }
    }

    private func makeStroke(path: CGPath, width: CGFloat, opacity: Float, length: Double) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.path = path
        layer.fillColor = nil
        layer.strokeColor = NSColor.white.cgColor
        layer.lineWidth = width
        layer.lineCap = .round
        layer.opacity = opacity
        layer.strokeStart = 0
        layer.strokeEnd = 0
        layer.contentsScale = window?.backingScaleFactor ?? 2
        layer.add(Self.travelAnimation(length: length), forKey: "travel")
        return layer
    }

    /// The head runs from 0 to 1 + the longest trail, so every copy leaves the
    /// curve before the next lap.
    private static func travelAnimation(length: Double) -> CAAnimation {
        let travel = 1 + trails[0].length

        let end = CAKeyframeAnimation(keyPath: "strokeEnd")
        end.values = [0, 1, 1]
        end.keyTimes = [0, NSNumber(value: 1 / travel), 1]

        let start = CAKeyframeAnimation(keyPath: "strokeStart")
        start.values = [0, 0, 1, 1]
        start.keyTimes = [0, NSNumber(value: length / travel), NSNumber(value: min(1, (1 + length) / travel)), 1]

        return lap([end, start])
    }

    /// Eases in at the source and out at the destination.
    private static func fadeAnimation() -> CAAnimation {
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.2, 0.65, 0.95]
        return lap([fade])
    }

    private static func lap(_ animations: [CAAnimation]) -> CAAnimation {
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = period
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        // Every glint starts its lap at the same moment, even ones added later.
        let now = CACurrentMediaTime()
        group.beginTime = now - now.truncatingRemainder(dividingBy: period)
        return group
    }
}

/// Animatable so strands glide to new positions when the flow changes.
private struct FlowCurve: Shape {
    var start: CGPoint
    var end: CGPoint

    var animatableData: AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData> {
        get { AnimatablePair(start.animatableData, end.animatableData) }
        set {
            start.animatableData = newValue.first
            end.animatableData = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        PowerFlowRibbonDiagram.path(from: start, to: end)
    }
}

private struct OptionalTooltip: ViewModifier {
    let text: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}
