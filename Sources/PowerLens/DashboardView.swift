import Charts
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: PowerLensStore
    let openSettings: () -> Void
    @SceneStorage("dashboard.sidebar.selection") private var selectedDestinationRaw = DashboardSidebarDestination.dashboard.rawValue
    /// The last hour of saved history behind the Mac card and hour chart.
    @State private var recentPower: [RecentPowerSample] = []

    private var selectedDestination: DashboardSidebarDestination {
        DashboardSidebarDestination(rawValue: selectedDestinationRaw) ?? .dashboard
    }

    private var sidebarSelection: Binding<String?> {
        Binding(
            get: { selectedDestination.rawValue },
            set: { newValue in
                selectedDestinationRaw = newValue ?? DashboardSidebarDestination.dashboard.rawValue
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.lensWindowBackground)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1120, minHeight: 760)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 24, height: 24)
                Text(L10n.text("ui.dashboardTitle"))
                    .font(.headline)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 10)

            List(selection: sidebarSelection) {
                ForEach(DashboardSidebarDestination.allCases) { destination in
                    Label(destination.title, systemImage: destination.systemImage)
                        .tag(Optional(destination.rawValue))
                }
            }
            .listStyle(.sidebar)

            if let snapshot = store.latest {
                sidebarStatus(snapshot)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            SidebarFooterAction(
                title: L10n.text("ui.section.settings"),
                systemImage: "gearshape",
                action: openSettings
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 260)
    }

    private func sidebarStatus(_ snapshot: TelemetrySnapshot) -> some View {
        let status = PowerStatusPresentation(snapshot: snapshot, resolvedState: store.resolvedPowerState)
        let battery = MetricTilePresentation.battery(snapshot: snapshot, resolvedState: store.resolvedPowerState)
        let mac = PowerFlowReadings(snapshot: snapshot).systemPower?.formatted ?? L10n.text("common.none")

        return VStack(alignment: .leading, spacing: 6) {
            StatusCapsule(title: status.capsuleTitle, systemImage: status.capsuleSymbol, tone: status.tone)
            Text(L10n.tr("sidebar.status.detail", battery.value, mac))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCardSurface(cornerRadius: 12)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailSurface: some View {
        if selectedDestination == .history || store.latest != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedDestination {
                    case .dashboard:
                        if let snapshot = store.latest {
                            nowPage(snapshot)
                        }
                    case .battery:
                        if let snapshot = store.latest {
                            batteryPage(snapshot)
                        }
                    case .history:
                        historyPage
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if store.telemetryUnavailable {
            VStack(spacing: Spacing.medium) {
                Image(systemName: "bolt.slash")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(L10n.text("ui.telemetryUnavailable.title"))
                    .font(.title3.weight(.semibold))
                Text(L10n.text("ui.telemetryUnavailable.message"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(Spacing.xxLarge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            ProgressView(L10n.text("ui.readingBatteryTelemetry"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func pageHeader(
        capsule: StatusCapsule?,
        meta: @escaping (Date) -> String?,
        title: String,
        subtitle: String?,
        showsRefresh: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    if let capsule {
                        capsule
                    }
                    // Data refreshes redraw this every few seconds anyway; the
                    // slow tick only keeps "N초 전" honest if refreshes stall.
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        if let text = meta(context.date) {
                            Text(text)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                }
                Text(title)
                    .font(.title.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                if let subtitle {
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            if showsRefresh {
                Button(action: store.refreshNow) {
                    Label(L10n.text("ui.refresh"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
    }

    // MARK: - 지금

    private func nowPage(_ snapshot: TelemetrySnapshot) -> some View {
        let status = PowerStatusPresentation(snapshot: snapshot, resolvedState: store.resolvedPowerState)
        let readings = PowerFlowReadings(snapshot: snapshot)
        let graph = PowerFlowGraph(model: PowerFlowPresentationModel(snapshot: snapshot))

        return VStack(alignment: .leading, spacing: 20) {
            pageHeader(
                capsule: StatusCapsule(title: status.capsuleTitle, systemImage: status.capsuleSymbol, tone: status.tone),
                meta: { freshnessMeta(now: $0) },
                title: status.title,
                subtitle: status.subtitle,
                showsRefresh: true
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
                    tooltip: PowerFlowTooltip.text(snapshot: snapshot, readings: readings)
                )
            }
            .padding(22)
            .cardSurface()

            HStack(alignment: .top, spacing: 16) {
                batteryCard(snapshot)
                chargerCard(snapshot, readings: readings)
                macCard(readings: readings)
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 16) {
                hourChartCard
                insightsCard(snapshot)
                    .frame(width: 320)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        // A new history row lands once a minute; reload only then, and only
        // while this page is on screen.
        .task(id: store.historyRevision) {
            recentPower = await store.recentPowerHistory()
        }
    }

    private func freshnessMeta(now: Date) -> String? {
        let freshness = TelemetryFreshness(
            refreshDate: store.lastRefreshAt ?? store.latest?.timestamp,
            health: store.telemetryHealth,
            now: now
        )
        let age: String
        switch freshness.state {
        case .live:
            age = L10n.text("ui.updated.justNow")
        case .waiting:
            age = L10n.text("telemetry.live.waiting")
        case .delayed:
            age = (store.lastRefreshAt).map { L10n.tr("ui.updated.stale", Formatters.relativeAge(since: $0, now: now)) }
                ?? L10n.text("telemetry.delayed")
        case .unavailable:
            age = L10n.text("telemetry.unavailable")
        }
        return "\(age) · \(store.activeTelemetryEngine.displayName)"
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

    private func batteryCard(_ snapshot: TelemetrySnapshot) -> some View {
        let tile = MetricTilePresentation.battery(snapshot: snapshot, resolvedState: store.resolvedPowerState)
        let limit = Self.chargeLimit(store.resolvedPowerState?.managedChargingState ?? snapshot.managedChargingState)
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
                fraction: (snapshot.batteryLevel ?? 0) / 100,
                tint: tint,
                marker: limit.map { Double($0) / 100 }
            )
        }
    }

    private func chargerCard(_ snapshot: TelemetrySnapshot, readings: PowerFlowReadings) -> some View {
        let input = readings.inputPower?.watts
        let rated = snapshot.adapterMaxPowerW
        let fraction = (input ?? 0) / max(rated ?? 0, 1)

        return DashboardMetricCard(
            title: L10n.text("flow.node.charger"),
            systemImage: "powerplug.fill",
            iconTint: LensPalette.charger,
            value: snapshot.externalConnected ? (input.map(Formatters.power) ?? L10n.text("common.none")) : L10n.text("common.none"),
            unit: snapshot.externalConnected ? rated.map { "/ \(Formatters.ratedPower($0))" } : nil,
            caption: chargerCaption(snapshot: snapshot, fraction: fraction)
        ) {
            BarGauge(
                fraction: snapshot.externalConnected && rated != nil ? fraction : 0,
                tint: LensPalette.charger
            )
        }
    }

    private func chargerCaption(snapshot: TelemetrySnapshot, fraction: Double) -> String {
        guard snapshot.externalConnected else {
            return L10n.text("charger.usage.disconnected")
        }
        guard snapshot.adapterMaxPowerW != nil else {
            return L10n.text("charger.usage.unknownRating")
        }
        switch fraction {
        case ..<0.35: return L10n.text("charger.usage.light")
        case ..<0.7: return L10n.text("charger.usage.half")
        case ..<0.9: return L10n.text("charger.usage.high")
        default: return L10n.text("charger.usage.full")
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
            caption: average.map { L10n.tr("tile.mac.average", Formatters.power($0)) } ?? L10n.text("tile.mac.collecting")
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
            if recentPower.count >= 2 {
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

    private func insightsCard(_ snapshot: TelemetrySnapshot) -> some View {
        let diagnostics = snapshot.diagnosticsExcludingPrimaryStatus(
            store.diagnostics,
            resolvedState: store.resolvedPowerState
        )
        .filter { $0.kind != .healthy }
        let health = MetricTilePresentation.health(snapshot: snapshot)
        let assessment = BatteryHealthPresentation(snapshot.batteryHealthAssessment)
        let temperature = MetricTilePresentation.temperature(snapshot: snapshot)

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
                title: L10n.isKnownThermalState(snapshot.thermalState)
                    ? L10n.tr("insight.temperature", temperature.caption)
                    : L10n.text("insight.temperature.unknown"),
                detail: snapshot.batteryTemperatureC.map(Formatters.temperature)
            )

            if let app = store.topEnergyApps.first {
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

    // MARK: - 배터리

    private func batteryPage(_ snapshot: TelemetrySnapshot) -> some View {
        let health = snapshot.chargeHealthPercent
        let assessment = BatteryHealthPresentation(snapshot.batteryHealthAssessment)

        return VStack(alignment: .leading, spacing: 20) {
            pageHeader(
                capsule: StatusCapsule(title: assessment.capsuleTitle, systemImage: "heart.fill", tone: assessment.tone),
                meta: { _ in snapshot.cycleCount.map { L10n.tr("battery.meta.cycles", $0) } },
                title: assessment.title,
                subtitle: health.map { L10n.tr("battery.subtitle.capacity", Formatters.percent($0)) },
                showsRefresh: false
            )

            capacityCard(snapshot)

            HStack(alignment: .top, spacing: 16) {
                DashboardMetricCard(
                    title: L10n.text("ui.metric.cycles"),
                    systemImage: "arrow.triangle.2.circlepath",
                    iconTint: .secondary,
                    value: snapshot.cycleCount.map(String.init) ?? L10n.text("common.none"),
                    unit: snapshot.cycleCount != nil ? L10n.text("format.cycleUnit") : nil,
                    caption: snapshot.designCycleCount.map { L10n.tr("ui.metric.designTarget", $0) }
                        ?? L10n.text("ui.metric.cycleTargetUnknown")
                ) {
                    BarGauge(
                        fraction: Double(snapshot.cycleCount ?? 0) / Double(max(snapshot.designCycleCount ?? 1000, 1)),
                        tint: .secondary
                    )
                }

                DashboardMetricCard(
                    title: L10n.text("ui.metric.batteryTemp"),
                    systemImage: "thermometer.medium",
                    iconTint: .secondary,
                    value: snapshot.batteryTemperatureC.map(Formatters.temperature) ?? L10n.text("common.none"),
                    caption: L10n.tr("battery.temperature.caption", L10n.localizedThermalState(snapshot.thermalState))
                ) {
                    TemperatureZones(temperature: snapshot.batteryTemperatureC)
                }

                chargingMethodCard(snapshot)
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 16) {
                detailCard(title: L10n.text("ui.detail.batteryPack"), rows: TelemetryDetailRows.batteryPack(snapshot))
                detailCard(title: L10n.text("ui.detail.batteryFlow"), rows: TelemetryDetailRows.batteryFlow(snapshot))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func capacityCard(_ snapshot: TelemetrySnapshot) -> some View {
        let health = snapshot.chargeHealthPercent
        let tint = (health ?? 100) < 80 ? LensPalette.caution : LensPalette.battery

        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.text("ui.metric.health"), systemImage: "heart.fill")
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .labelStyle(TintedIconLabelStyle(tint: tint))
                    Text(health.map(Formatters.percent) ?? L10n.text("common.none"))
                        .font(.system(size: 32, weight: .semibold))
                        .monospacedDigit()
                }
                Spacer()
                capacityFact(L10n.text("ui.detail.designCapacity"), snapshot.designCapacityMah)
                capacityFact(L10n.text("ui.detail.fullChargeCapacity"), snapshot.fullChargeCapacityMah)
            }

            VStack(spacing: 8) {
                BarGauge(fraction: (health ?? 0) / 100, tint: tint, marker: 0.8)
                HStack {
                    Text("0%")
                    Spacer()
                    Text(L10n.text("battery.capacity.serviceMark"))
                    Spacer()
                    Text("100%")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(24)
        .cardSurface()
    }

    private func capacityFact(_ title: String, _ mah: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(mah.map(Formatters.capacity) ?? L10n.text("common.none"))
                .font(.headline)
                .monospacedDigit()
        }
        .padding(.top, 6)
    }

    private func chargingMethodCard(_ snapshot: TelemetrySnapshot) -> some View {
        let state = store.resolvedPowerState?.managedChargingState ?? snapshot.managedChargingState
        let value: String
        let caption: String
        if let limit = Self.chargeLimit(state) {
            value = Formatters.percent(Double(limit))
            caption = L10n.tr("battery.charging.limitCaption", Formatters.percent(Double(limit)))
        } else if case .some(.optimizedCharging) = state {
            value = L10n.text("battery.charging.optimized")
            caption = L10n.text("battery.charging.optimizedCaption")
        } else if case .some(.optimizedHold) = state {
            value = L10n.text("battery.charging.optimized")
            caption = L10n.text("battery.charging.optimizedCaption")
        } else if case .some(.optimizedActive) = state {
            value = L10n.text("battery.charging.optimized")
            caption = L10n.text("battery.charging.optimizedCaption")
        } else {
            value = L10n.text("battery.charging.default")
            caption = L10n.text("battery.charging.defaultCaption")
        }

        return DashboardMetricCard(
            title: L10n.text("battery.charging.title"),
            systemImage: "bolt.batteryblock",
            iconTint: LensPalette.charger,
            value: value,
            caption: caption
        ) {
            BarGauge(
                fraction: Self.chargeLimit(state).map { Double($0) / 100 } ?? 1,
                tint: LensPalette.charger
            )
        }
    }

    private func detailCard(title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack {
                        Text(row.0)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(row.1)
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.vertical, 9)

                    if index < rows.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
    }

    // MARK: - 기록

    private var historyPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("ui.sidebar.history"))
                    .font(.title.weight(.bold))
                Text(L10n.text("history.subtitle"))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            InsightsView(store: store)
        }
    }

    // MARK: - Helpers

    static func chargeLimit(_ state: ManagedChargingState?) -> Int? {
        switch state {
        case let .chargingToLimit(target), let .chargingBeyondLimit(target),
             let .aboveConfiguredLimit(target), let .reducingToLimit(target),
             let .holdingAtLimit(target), let .limitConfigured(target):
            target
        case .optimizedCharging, .optimizedHold, .optimizedActive, nil:
            nil
        }
    }
}

/// Cool / warm / hot bands with the current temperature marked.
private struct TemperatureZones: View {
    let temperature: Double?
    private let scale = 45.0

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                HStack(spacing: 3) {
                    Capsule().fill(LensPalette.battery.opacity(0.35)).frame(width: width * 35 / scale - 3)
                    Capsule().fill(LensPalette.caution.opacity(0.35)).frame(width: width * 5 / scale - 3)
                    Capsule().fill(LensPalette.warning.opacity(0.35))
                }
                if let temperature {
                    Circle()
                        .strokeBorder(.primary, lineWidth: 3)
                        .background(Circle().fill(Color.lensWindowCard))
                        .frame(width: 14, height: 14)
                        .offset(x: width * min(max(temperature, 0), scale) / scale - 7)
                }
            }
        }
        .frame(height: 8)
    }
}

private struct TintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}
