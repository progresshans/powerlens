import CoreGraphics
import Testing
@testable import PowerLens

struct PowerFlowGraphTests {
    private func graph(_ snapshot: TelemetrySnapshot) -> PowerFlowGraph {
        PowerFlowGraph(model: PowerFlowPresentationModel(snapshot: snapshot))
    }

    private var chargingSnapshot: TelemetrySnapshot {
        makeTelemetrySnapshot(
            isCharging: true,
            batteryCurrentA: 3.44,
            batteryPowerW: -46.4,
            adapterInputPowerW: 53.6,
            systemLoadW: 7.2
        )
    }

    @Test
    func chargingSplitsTheChargerIntoMacAndBattery() {
        let graph = graph(chargingSnapshot)

        #expect(graph.state == .charging)
        #expect(graph.sources.map(\.endpoint) == [.charger])
        #expect(graph.destinations.map(\.endpoint) == [.mac, .battery])
        #expect(graph.sources.first?.value == "53.6W")
        #expect(graph.destinations.map(\.value) == ["7.2W", "46.4W"])
        #expect(graph.links == [
            .init(from: .charger, to: .mac, watts: 7.2),
            .init(from: .charger, to: .battery, watts: 46.4),
        ])
    }

    @Test
    func batteryAssistMergesChargerAndBatteryIntoMac() {
        let graph = graph(makeTelemetrySnapshot(
            batteryCurrentA: -0.4,
            batteryPowerW: 3.8,
            adapterInputPowerW: 9.1,
            systemLoadW: 12.9
        ))

        #expect(graph.state == .underpowered)
        #expect(graph.sources.map(\.endpoint) == [.charger, .battery])
        #expect(graph.destinations.map(\.endpoint) == [.mac])
        #expect(graph.links.map(\.from) == [.charger, .battery])
        #expect(graph.links.allSatisfy { $0.to == .mac })
    }

    @Test
    func holdingLeavesTheRestingBatteryOut() {
        let graph = graph(makeTelemetrySnapshot(
            batteryCurrentA: 0,
            batteryPowerW: 0,
            adapterInputPowerW: 11.7,
            systemLoadW: 11.7
        ))

        #expect(graph.state == .holding)
        #expect(graph.sources.map(\.endpoint) == [.charger])
        #expect(graph.destinations.map(\.endpoint) == [.mac])
        #expect(graph.links == [.init(from: .charger, to: .mac, watts: 11.7)])
    }

    @Test
    func batteryOnlyDrawsOneRibbon() {
        let graph = graph(makeTelemetrySnapshot(
            powerSource: .battery,
            externalConnected: false,
            timeToEmptyMinutes: 240,
            batteryCurrentA: -0.82,
            batteryPowerW: 9.1,
            adapterInputPowerW: 0,
            systemLoadW: 9.1,
            adapterMaxPowerW: nil
        ))

        #expect(graph.sources.map(\.endpoint) == [.battery])
        #expect(graph.links == [.init(from: .battery, to: .mac, watts: 9.1)])
    }

    @Test
    func unbalancedReadingsShowNodesButNoRibbons() {
        let graph = graph(makeTelemetrySnapshot(
            batteryCurrentA: nil,
            batteryPowerW: nil,
            adapterInputPowerW: nil,
            systemLoadW: nil
        ))

        #expect(graph.state == .unknown)
        #expect(graph.links.isEmpty)
        #expect(graph.sources.first?.value == L10n.text("common.none"))
    }

    @Test
    func unbalancedFlowKeepsTheKnownMacReading() {
        // Battery direction is known but its wattage is missing, so the flow
        // cannot balance. The system sensor still reads 15 W, as the menu bar
        // and the Dashboard card show.
        let graph = graph(makeTelemetrySnapshot(
            batteryVoltageV: nil, batteryCurrentA: -1, batteryPowerW: nil,
            adapterInputPowerW: 10, systemLoadW: 15
        ))

        #expect(graph.state == .unknown)
        #expect(graph.links.isEmpty)
        #expect(graph.sources.map(\.value) == [L10n.text("common.none")])
        #expect(graph.destinations.map(\.endpoint) == [.mac])
        #expect(graph.destinations.first?.value == "15.0W")
    }

    @Test
    func ribbonWidthFollowsWattsGently() {
        let metrics = PowerFlowRibbonLayout.Metrics.compact
        let layout = PowerFlowRibbonLayout(
            graph: graph(chargingSnapshot),
            size: CGSize(width: 308, height: 104),
            metrics: metrics
        )

        #expect(layout.ribbons.count == 2)
        #expect(layout.ribbons.map(\.width) == [metrics.width(for: 7.2), metrics.width(for: 46.4)])
        #expect(layout.ribbons[0].width < layout.ribbons[1].width)
        // Six times the watts reads heavier, but never six times as thick.
        #expect(layout.ribbons[1].width < layout.ribbons[0].width * 2)
    }

    @Test
    func splitStrandsShareTheSourceAnchorAndLandOnEachDestination() {
        let layout = PowerFlowRibbonLayout(
            graph: graph(chargingSnapshot),
            size: CGSize(width: 308, height: 104),
            metrics: .compact,
            labelWidths: [.charger: 40, .mac: 50, .battery: 60]
        )

        #expect(layout.ribbons.allSatisfy { $0.start == CGPoint(x: 40 + 12, y: 52) })
        #expect(layout.ribbons.map(\.end) == [
            CGPoint(x: 308 - 50 - 12, y: 26),
            CGPoint(x: 308 - 60 - 12, y: 78),
        ])
    }

    @Test
    func unmeasuredFlowGetsAQuietDottedRoute() {
        let layout = PowerFlowRibbonLayout(
            graph: graph(makeTelemetrySnapshot(
                batteryCurrentA: nil,
                batteryPowerW: nil,
                adapterInputPowerW: nil,
                systemLoadW: nil
            )),
            size: CGSize(width: 308, height: 60),
            metrics: .compact
        )

        #expect(layout.ribbons.map(\.isResting) == [true])
        #expect(layout.ribbons.first?.to == .mac)
        #expect(layout.ribbons.first?.width == PowerFlowRibbonLayout.restingWidth)
    }

    @Test
    func ribbonWidthIsClampedForVeryLargeAndTinyFlows() {
        let heavy = PowerFlowGraph.Link(from: .charger, to: .mac, watts: 400)
        let tiny = PowerFlowGraph.Link(from: .battery, to: .mac, watts: 0.5)
        let base = graph(makeTelemetrySnapshot(
            batteryCurrentA: -0.4,
            batteryPowerW: 3.8,
            adapterInputPowerW: 9.1,
            systemLoadW: 12.9
        ))
        let graph = PowerFlowGraphTestDouble.replacingLinks(of: base, with: [heavy, tiny])
        let metrics = PowerFlowRibbonLayout.Metrics.compact
        let layout = PowerFlowRibbonLayout(graph: graph, size: CGSize(width: 308, height: 104), metrics: metrics)

        let widths = layout.ribbons.map(\.width)
        #expect(widths[0] == metrics.maxWidth)
        #expect(widths[1] > metrics.minWidth && widths[1] < metrics.minWidth + 1)
    }
}

private enum PowerFlowGraphTestDouble {
    static func replacingLinks(of graph: PowerFlowGraph, with links: [PowerFlowGraph.Link]) -> PowerFlowGraph {
        PowerFlowGraph(state: graph.state, sources: graph.sources, destinations: graph.destinations, links: links)
    }
}
