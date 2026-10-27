import Charts
import SwiftUI

struct DashboardNowPage: View {
    let snapshot: TelemetrySnapshot
    let presentation: LivePowerPresentation
    let live: LiveTelemetryState
    let energyApps: [AppEnergyUsage]
    let historyRevision: Int
    let refresh: () -> Void
    let loadRecent: @MainActor () async throws -> [RecentPowerSample]
    @ObservedObject var recentHistory: RecentPowerHistoryModel

    private var recentPower: [RecentPowerSample] { recentHistory.samples }

    var body: some View {
        let status = presentation.status
        let readings = presentation.readings
        let graph = presentation.graph

        return VStack(alignment: .leading, spacing: 20) {
            DashboardPageHeader(
                capsule: StatusCapsule(title: status.capsuleTitle, systemImage: status.capsuleSymbol, tone: status.tone),
                meta: { freshnessMeta(now: $0) },
                title: status.title,
                subtitle: status.subtitle,
                showsRefresh: true, refresh: refresh
            )

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(L10n.text("ui.section.flow"))
                        .font(.headline)
                    Spacer()
                    HStack(spacing: 14) {
                        LegendItem(title: L10n.text("flow.node.charger"), color: LensPalette.charger)
                        LegendItem(title: L10n.text("flow.node.battery"), color: LensPalette.battery)
                        LegendItem(title: L10n.text("flow.node.mac"), color: LensPalette.mac)
                    }
                }
                PowerFlowRibbonDiagram(
                    graph: graph,
                    style: .large,
                    notes: flowNotes(snapshot: snapshot, graph: graph, readings: readings),
                    batteryLevel: snapshot.batteryLevel,
                    tooltip: presentation.tooltip
                )
            }
            .padding(22)
            .cardSurface()
            .opacity(presentation.isAwaitingSource ? 0.4 : 1)

            HStack(alignment: .top, spacing: 16) {
                batteryCard(snapshot, tile: presentation.battery)
                chargerCard(usage: presentation.charger)
                macCard(readings: readings)
            }
            .fixedSize(horizontal: false, vertical: true)
            .opacity(presentation.isAwaitingSource ? 0.4 : 1)

            HStack(alignment: .top, spacing: 16) {
                hourChartCard
                insightsCard(snapshot, presentation: presentation)
                    .frame(width: 320)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        // A new history row lands once a minute; reload only then, and only
        // while this page is on screen.
        .task(id: historyRevision) {
            await recentHistory.load(using: loadRecent)
        }
    }

    private func freshnessMeta(now: Date) -> String? {
        let freshness = TelemetryFreshness(
            refreshDate: snapshot.timestamp,
            health: live.health,
            now: now
        )
        return "\(freshness.updatedText) · \(live.activeEngine.displayName)"
    }

    private func flowNotes(
        snapshot: TelemetrySnapshot,
        graph: PowerFlowGraph,
        readings: PowerFlowReadings
    ) -> [PowerFlowGraph.Endpoint: String] {
        var notes: [PowerFlowGraph.Endpoint: String] = [.mac: L10n.text("flow.note.mac")]
        if let rated = snapshot.adapterMaxPowerW, rated > 0, let input = readings.inputPower {
            notes[.charger] = L10n.tr(
                "flow.note.ofRated",
                Formatters.ratedPower(rated),
                Formatters.percent(min(100, input.watts / rated * 100))
            )
        }
        switch graph.state {
        case .charging:
            notes[.battery] = L10n.text("flow.note.batteryCharging")
        case .underpowered, .discharging:
            notes[.battery] = L10n.text("flow.note.batteryDischarging")
        case .holding, .directPower, .unknown:
            break
        }
        return notes
    }

    private func batteryCard(_ snapshot: TelemetrySnapshot, tile: MetricTilePresentation) -> some View {
        let limit = (live.resolvedState?.managedChargingState ?? snapshot.managedChargingState)?.targetPercent
        let tint = snapshot.lowPowerModeEnabled ? LensPalette.lowPower : LensPalette.battery

        return DashboardMetricCard(
            title: tile.label,
            systemImage: tile.symbol,
            iconTint: tint,
            value: tile.value,
            trailingNote: limit.map { L10n.tr("tile.battery.limit", Formatters.percent(Double($0))) },
            caption: tile.caption
        ) {
            BarGauge(
                fraction: DashboardGauge.batteryLevel(snapshot),
                tint: tint,
                marker: limit.map { Double($0) / 100 }
            )
        }
    }

    private func chargerCard(usage: ChargerUsagePresentation) -> some View {

        return DashboardMetricCard(
            title: L10n.text("flow.node.charger"),
            systemImage: "powerplug.fill",
            iconTint: LensPalette.charger,
            value: usage.value,
            unit: usage.unit,
            caption: usage.caption
        ) {
            BarGauge(fraction: usage.fraction, tint: LensPalette.charger)
        }
    }

    private func macCard(readings: PowerFlowReadings) -> some View {
        let values = recentPower.compactMap(\.systemW)
        let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)

        return DashboardMetricCard(
            title: L10n.text("ui.metric.systemLoad"),
            systemImage: "laptopcomputer",
            iconTint: LensPalette.mac,
            value: readings.systemPower?.formatted ?? L10n.text("common.none"),
            caption: recentHistory.hasReadFailure ? L10n.text("tile.mac.historyUnavailable")
                : average.map { L10n.tr("tile.mac.average", Formatters.power($0)) } ?? L10n.text("tile.mac.collecting")
        ) {
            RecentPowerChart(samples: recentPower, showsInput: false, compact: true)
                .frame(height: 24)
        }
    }

    private var hourChartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.text("dashboard.lastHour"))
                    .font(.headline)
                Spacer()
                HStack(spacing: 14) {
                    LegendItem(title: L10n.text("flow.node.charger"), color: LensPalette.charger)
                    LegendItem(title: L10n.text("ui.metric.systemLoad"), color: LensPalette.mac)
                }
            }
            if recentHistory.hasReadFailure {
                Text(L10n.text("history.status.degraded.detail"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
            } else if recentPower.count >= 2 {
                RecentPowerChart(samples: recentPower)
                    .frame(height: 150)
            } else {
                Text(L10n.text("dashboard.lastHour.collecting"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
    }

    private func insightsCard(_ snapshot: TelemetrySnapshot, presentation: LivePowerPresentation) -> some View {
        let diagnostics = presentation.diagnostics.filter { $0.kind != .healthy }
        let health = presentation.health
        let assessment = BatteryHealthPresentation(snapshot.batteryHealthAssessment)
        let temperature = presentation.temperature

        return VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("dashboard.insights"))
                .font(.headline)
                .padding(.bottom, 4)

            ForEach(diagnostics.prefix(2)) { item in
                InsightRow(
                    systemImage: item.severity == .info ? "info.circle.fill" : "exclamationmark.triangle.fill",
                    tint: item.severity == .warning ? LensPalette.warning : (item.severity == .caution ? LensPalette.caution : LensPalette.charger),
                    title: item.title,
                    detail: item.message
                )
            }

            InsightRow(
                systemImage: assessment.symbol,
                tint: assessment.tone.tint,
                title: assessment.title,
                detail: L10n.tr(
                    "insight.health.detail",
                    health.value,
                    snapshot.cycleCount.map { L10n.tr("format.cycleCount", $0) } ?? L10n.text("common.none")
                )
            )

            InsightRow(
                systemImage: "thermometer.medium",
                tint: temperature.captionTone == .neutral ? .secondary : temperature.captionTone.tint,
                title: DashboardInsight.temperatureTitle(snapshot: snapshot),
                detail: snapshot.batteryTemperatureC.map(Formatters.temperature)
            )

            if let app = energyApps.first {
                InsightRow(
                    systemImage: "bolt.fill",
                    tint: LensPalette.caution,
                    title: L10n.tr("insight.topApp", app.name),
                    detail: nil
                )
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
    }

}
