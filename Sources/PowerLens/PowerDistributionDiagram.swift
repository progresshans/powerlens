import SwiftUI

enum DistributionPalette {
    static let input = Color(red: 0.21, green: 0.53, blue: 0.94)
    static let system = Color(red: 0.95, green: 0.52, blue: 0.20)
    static let battery = Color(red: 0.95, green: 0.65, blue: 0.22)
    static let charge = Color(red: 0.33, green: 0.74, blue: 0.42)
    static let mergedFlow = Color(red: 0.58, green: 0.48, blue: 0.78)

    static func tint(for role: PowerFlowEndpointRole) -> Color {
        switch role {
        case .input:
            input
        case .system:
            system
        case .battery:
            battery
        case .charge:
            charge
        }
    }
}

struct PowerDistributionDiagram: View {
    let rows: [PowerFlowRouteModel]
    let density: PowerFlowCardDensity

    private var layoutKind: PowerDistributionLayoutKind {
        guard rows.count >= 2 else {
            return .single
        }

        let firstSource = rows[0].source.identity
        let firstTarget = rows[0].target.identity
        let hasSameSource = rows.allSatisfy { $0.source.identity == firstSource }
        let hasSameTarget = rows.allSatisfy { $0.target.identity == firstTarget }

        if hasSameTarget {
            return .merge
        }
        if hasSameSource {
            return .split
        }
        return .parallel
    }

    private var diagramHeight: CGFloat {
        switch (density, rows.count > 1) {
        case (.compact, true):
            132
        case (.compact, false):
            88
        case (.regular, true):
            154
        case (.regular, false):
            104
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = DiagramMetrics(size: proxy.size, density: density)
            let layout = makeLayout(metrics: metrics)

            ZStack {
                Canvas { context, _ in
                    for band in layout.bands {
                        drawBand(band, in: &context, density: density)
                    }
                }

                ForEach(layout.nodes) { node in
                    PowerDistributionEndpointCard(
                        endpoint: node.endpoint,
                        alignment: node.alignment,
                        density: density
                    )
                    .frame(width: metrics.nodeWidth)
                    .position(node.center)
                }
            }
        }
        .frame(height: diagramHeight)
    }

    private func makeLayout(metrics: DiagramMetrics) -> PowerDistributionDiagramLayout {
        guard let firstRow = rows.first else {
            return PowerDistributionDiagramLayout(nodes: [], bands: [])
        }

        switch layoutKind {
        case .single:
            return singleLayout(row: firstRow, metrics: metrics)
        case .merge:
            return mergeLayout(metrics: metrics)
        case .split:
            return splitLayout(metrics: metrics)
        case .parallel:
            return parallelLayout(metrics: metrics)
        }
    }

    private func singleLayout(row: PowerFlowRouteModel, metrics: DiagramMetrics) -> PowerDistributionDiagramLayout {
        let source = CGPoint(x: metrics.leftX, y: metrics.centerY)
        let target = CGPoint(x: metrics.rightX, y: metrics.centerY)
        let start = metrics.trailingEdge(of: source)
        let end = metrics.leadingEdge(of: target)
        return PowerDistributionDiagramLayout(
            nodes: [
                .init(id: "source", endpoint: row.source, alignment: .leading, center: source),
                .init(id: "target", endpoint: row.target, alignment: .trailing, center: target),
            ],
            bands: [
                .init(
                    id: "single",
                    start: start,
                    end: end,
                    startTint: DistributionPalette.tint(for: row.role),
                    endTint: DistributionPalette.tint(for: row.role),
                    hasSoftCaps: true
                ),
            ],
        )
    }

    private func mergeLayout(metrics: DiagramMetrics) -> PowerDistributionDiagramLayout {
        let sourceCenters = stackedCenters(x: metrics.leftX, metrics: metrics)
        let target = CGPoint(x: metrics.rightX, y: metrics.centerY)
        let junction = CGPoint(x: metrics.leadingEdge(of: target).x - metrics.junctionOffset, y: metrics.centerY)
        let targetEnd = metrics.leadingEdge(of: target)
        let mergedTint = DistributionPalette.mergedFlow

        let nodes = zip(rows.indices, rows).map { index, row in
            PowerFlowDiagramNode(
                id: "source-\(index)",
                endpoint: row.source,
                alignment: .leading,
                center: sourceCenters[index]
            )
        } + [
            PowerFlowDiagramNode(id: "target", endpoint: rows[0].target, alignment: .trailing, center: target),
        ]

        let sourceBands = zip(rows.indices, rows).map { index, row in
            PowerFlowBand(
                id: "source-band-\(index)",
                start: metrics.trailingEdge(of: sourceCenters[index]),
                end: junction,
                startTint: DistributionPalette.tint(for: row.role),
                endTint: mergedTint,
                hasSoftCaps: false
            )
        }
        let trunkBand = PowerFlowBand(
            id: "merged-trunk",
            start: junction,
            end: targetEnd,
            startTint: mergedTint,
            endTint: mergedTint,
            hasSoftCaps: false
        )
        return PowerDistributionDiagramLayout(nodes: nodes, bands: sourceBands + [trunkBand])
    }

    private func splitLayout(metrics: DiagramMetrics) -> PowerDistributionDiagramLayout {
        let source = CGPoint(x: metrics.leftX, y: metrics.centerY)
        let targetCenters = stackedCenters(x: metrics.rightX, metrics: metrics)
        let junction = CGPoint(x: metrics.trailingEdge(of: source).x + metrics.junctionOffset, y: metrics.centerY)
        let sourceStart = metrics.trailingEdge(of: source)

        let nodes = [
            PowerFlowDiagramNode(id: "source", endpoint: rows[0].source, alignment: .leading, center: source),
        ] + zip(rows.indices, rows).map { index, row in
            PowerFlowDiagramNode(
                id: "target-\(index)",
                endpoint: row.target,
                alignment: .trailing,
                center: targetCenters[index]
            )
        }

        let trunkBand = PowerFlowBand(
            id: "split-trunk",
            start: sourceStart,
            end: junction,
            startTint: rows[0].source.tint,
            endTint: rows[0].source.tint,
            hasSoftCaps: false
        )
        let branchBands = zip(rows.indices, rows).map { index, row in
            PowerFlowBand(
                id: "branch-\(index)",
                start: junction,
                end: metrics.leadingEdge(of: targetCenters[index]),
                startTint: rows[0].source.tint,
                endTint: DistributionPalette.tint(for: row.role),
                hasSoftCaps: false
            )
        }
        return PowerDistributionDiagramLayout(nodes: nodes, bands: [trunkBand] + branchBands)
    }

    private func parallelLayout(metrics: DiagramMetrics) -> PowerDistributionDiagramLayout {
        let sourceCenters = stackedCenters(x: metrics.leftX, metrics: metrics)
        let targetCenters = stackedCenters(x: metrics.rightX, metrics: metrics)
        var nodes: [PowerFlowDiagramNode] = []
        var bands: [PowerFlowBand] = []

        for (index, row) in rows.enumerated() {
            let source = sourceCenters[index]
            let target = targetCenters[index]
            let start = metrics.trailingEdge(of: source)
            let end = metrics.leadingEdge(of: target)

            nodes.append(.init(id: "source-\(index)", endpoint: row.source, alignment: .leading, center: source))
            nodes.append(.init(id: "target-\(index)", endpoint: row.target, alignment: .trailing, center: target))
            bands.append(
                .init(
                    id: "band-\(index)",
                    start: start,
                    end: end,
                    startTint: DistributionPalette.tint(for: row.role),
                    endTint: DistributionPalette.tint(for: row.role),
                    hasSoftCaps: true
                )
            )
        }

        return PowerDistributionDiagramLayout(nodes: nodes, bands: bands)
    }

    private func stackedCenters(x: CGFloat, metrics: DiagramMetrics) -> [CGPoint] {
        if rows.count <= 1 {
            return [CGPoint(x: x, y: metrics.centerY)]
        }

        return [
            CGPoint(x: x, y: metrics.topY),
            CGPoint(x: x, y: metrics.bottomY),
        ]
    }

    private func drawBand(_ band: PowerFlowBand, in context: inout GraphicsContext, density: PowerFlowCardDensity) {
        let foregroundStyle = StrokeStyle(
            lineWidth: density == .compact ? 5 : 7,
            lineCap: band.hasSoftCaps ? .round : .butt,
            lineJoin: .round
        )
        let path = curvedPath(from: band.start, to: band.end)

        context.stroke(
            path,
            with: .linearGradient(
                Gradient(colors: foregroundColors(for: band)),
                startPoint: band.start,
                endPoint: band.end
            ),
            style: foregroundStyle
        )
    }

    private func foregroundColors(for band: PowerFlowBand) -> [Color] {
        [band.startTint.opacity(0.96), band.endTint.opacity(0.96)]
    }

    private func curvedPath(from start: CGPoint, to end: CGPoint) -> Path {
        let horizontalDistance = max(24, end.x - start.x)
        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + horizontalDistance * 0.46, y: start.y),
            control2: CGPoint(x: end.x - horizontalDistance * 0.46, y: end.y)
        )
        return path
    }
}

private enum PowerDistributionLayoutKind {
    case single
    case merge
    case split
    case parallel
}

private struct DiagramMetrics {
    let size: CGSize
    let density: PowerFlowCardDensity

    var nodeWidth: CGFloat {
        switch density {
        case .compact:
            min(max(size.width * 0.31, 116), 132)
        case .regular:
            min(max(size.width * 0.23, 154), 190)
        }
    }

    var centerY: CGFloat { size.height / 2 }
    var topY: CGFloat { size.height * 0.28 }
    var bottomY: CGFloat { size.height * 0.74 }
    var leftX: CGFloat { nodeWidth / 2 }
    var rightX: CGFloat { size.width - nodeWidth / 2 }
    var junctionOffset: CGFloat { density == .compact ? 42 : 58 }

    func trailingEdge(of center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + nodeWidth / 2 + 8, y: center.y)
    }

    func leadingEdge(of center: CGPoint) -> CGPoint {
        CGPoint(x: center.x - nodeWidth / 2 - 8, y: center.y)
    }
}

private struct PowerDistributionDiagramLayout {
    let nodes: [PowerFlowDiagramNode]
    let bands: [PowerFlowBand]
}

private struct PowerFlowDiagramNode: Identifiable {
    let id: String
    let endpoint: PowerFlowEndpointModel
    let alignment: HorizontalAlignment
    let center: CGPoint
}

private struct PowerFlowBand: Identifiable {
    let id: String
    let start: CGPoint
    let end: CGPoint
    let startTint: Color
    let endTint: Color
    let hasSoftCaps: Bool
}

private struct PowerDistributionEndpointCard: View {
    let endpoint: PowerFlowEndpointModel
    let alignment: HorizontalAlignment
    let density: PowerFlowCardDensity

    var body: some View {
        HStack(spacing: 8) {
            if alignment == .leading {
                endpointIcon
                endpointText
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                endpointText
                endpointIcon
            }
        }
        .padding(.horizontal, density == .compact ? 8 : 10)
        .padding(.vertical, density == .compact ? 8 : 9)
        .frame(maxWidth: .infinity, minHeight: density == .compact ? 56 : 58)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.05))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.8)
        }
    }

    private var endpointIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            endpoint.tint.opacity(0.18),
                            endpoint.tint.opacity(0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Image(systemName: endpoint.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(endpoint.tint)
        }
        .frame(width: density == .compact ? 22 : 24, height: density == .compact ? 22 : 24)
    }

    private var endpointText: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(endpoint.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.86)
                .multilineTextAlignment(textAlignment)
                .fixedSize(horizontal: false, vertical: true)

            Text(endpoint.value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .layoutPriority(1)
    }

    private var textAlignment: TextAlignment {
        alignment == .trailing ? .trailing : .leading
    }
}

private extension PowerFlowEndpointModel {
    var tint: Color {
        DistributionPalette.tint(for: role)
    }
}
