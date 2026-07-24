import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: PowerLensStore
    let openSettings: () -> Void
    @SceneStorage("dashboard.sidebar.selection") private var selectedDestinationRaw = DashboardSidebarDestination.dashboard.rawValue

    private let columns = [
        GridItem(.flexible(minimum: 190), spacing: 16, alignment: .top),
        GridItem(.flexible(minimum: 190), spacing: 16, alignment: .top),
        GridItem(.flexible(minimum: 190), spacing: 16, alignment: .top),
    ]

    private var selectedDestination: DashboardSidebarDestination {
        DashboardSidebarDestination(rawValue: selectedDestinationRaw) ?? .dashboard
    }

    private var sidebarSelection: Binding<String?> {
        Binding(
            get: { selectedDestinationRaw },
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
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1120, minHeight: 760)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("ui.dashboardTitle"))
                    .font(.title2.weight(.bold))
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 14)

            List(selection: sidebarSelection) {
                ForEach(DashboardSidebarDestination.allCases) { destination in
                    Label(destination.title, systemImage: destination.systemImage)
                        .tag(Optional(destination.rawValue))
                }
            }
            .listStyle(.sidebar)

            Divider()

            SidebarFooterAction(
                title: L10n.text("ui.section.settings"),
                systemImage: "gearshape",
                action: openSettings
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 260)
    }

    @ViewBuilder
    private var detailSurface: some View {
        if let snapshot = store.latest {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    detailHeader(snapshot)

                    switch selectedDestination {
                    case .dashboard:
                        dashboardSection(snapshot)
                    case .power:
                        powerSection(snapshot)
                    case .battery:
                        batterySection(snapshot)
                    case .diagnostics:
                        diagnosticsSection(snapshot)
                    case .history:
                        InsightsView(store: store)
                    }
                }
                .padding(28)
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
                    .font(.body)
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

    private func detailHeader(_ snapshot: TelemetrySnapshot) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(selectedDestination.detailTitle)
                    .font(.largeTitle.weight(.bold))

                Text(
                    snapshot.statusHeadline(
                        resolvedState: store.resolvedPowerState
                    )
                )
                    .font(.title3.weight(.semibold))

                Text(
                    snapshot.statusSubheadline(
                        resolvedState: store.resolvedPowerState
                    )
                )
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 12) {
                LiveIndicatorView(
                    refreshDate: store.lastRefreshAt ?? snapshot.timestamp,
                    activeEngineName: store.activeTelemetryEngine.displayName
                )

                DashboardHeaderAction(
                    systemImage: "arrow.clockwise",
                    title: L10n.text("ui.refreshNow"),
                    action: store.refreshNow
                )
            }
        }
    }

    private func dashboardSection(_ snapshot: TelemetrySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            LazyVGrid(columns: columns, spacing: 16) {
                metricCard(
                    L10n.text("ui.metric.battery"),
                    snapshot.batteryLevel.map(Formatters.percent) ?? L10n.text("common.none"),
                    detail: snapshot.externalConnected
                        ? snapshot.statusHeadline(
                            resolvedState: store.resolvedPowerState
                        )
                        : L10n.text("ui.metric.portablePower"),
                    systemImage: "battery.100"
                )
                metricCard(
                    L10n.text("ui.metric.powerIn"),
                    snapshot.adapterInputPowerW.map(Formatters.power) ?? L10n.text("common.none"),
                    detail: snapshot.adapterMaxPowerW.map { L10n.tr("ui.metric.ratedPowerDetail", Formatters.power($0)) } ?? L10n.text("ui.metric.adapterNotConnected"),
                    systemImage: "powerplug.fill"
                )
                metricCard(
                    L10n.text("ui.metric.systemLoad"),
                    snapshot.systemLoadW.map(Formatters.power) ?? L10n.text("common.none"),
                    detail: snapshot.frontmostAppName ?? L10n.text("ui.metric.noForegroundApp"),
                    systemImage: "waveform.path.ecg"
                )
                metricCard(
                    L10n.text("ui.metric.batteryTemp"),
                    snapshot.batteryTemperatureC.map(Formatters.temperature) ?? L10n.text("common.none"),
                    detail: L10n.tr("ui.metric.thermalStateDetail", L10n.localizedThermalState(snapshot.thermalState)),
                    systemImage: "thermometer.medium"
                )
                metricCard(
                    L10n.text("ui.metric.health"),
                    snapshot.chargeHealthPercent.map(Formatters.percent) ?? L10n.text("common.none"),
                    detail: snapshot.batteryHealthSummary,
                    systemImage: "heart.fill"
                )
                metricCard(
                    L10n.text("ui.metric.cycles"),
                    snapshot.cycleCount.map(String.init) ?? L10n.text("common.none"),
                    detail: snapshot.designCycleCount.map { L10n.tr("ui.metric.designTarget", $0) } ?? L10n.text("ui.metric.cycleTargetUnknown"),
                    systemImage: "repeat"
                )
            }

            PowerFlowCard(snapshot: snapshot)

            if !store.topEnergyApps.isEmpty {
                EnergyUsageCard(apps: store.topEnergyApps)
            }

            diagnosticsBlock
        }
    }

    private func powerSection(_ snapshot: TelemetrySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            PowerFlowCard(snapshot: snapshot)

            if !store.topEnergyApps.isEmpty {
                EnergyUsageCard(apps: store.topEnergyApps)
            }

            LazyVGrid(columns: columns, spacing: 16) {
                detailCard(title: L10n.text("ui.detail.adapter"), rows: TelemetryDetailRows.adapter(snapshot))
                detailCard(title: L10n.text("ui.detail.system"), rows: TelemetryDetailRows.system(snapshot, lastRefreshAt: store.lastRefreshAt))
                detailCard(title: L10n.text("ui.section.powerSnapshot"), rows: TelemetryDetailRows.powerSnapshot(snapshot))
            }
        }
    }

    private func batterySection(_ snapshot: TelemetrySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            LazyVGrid(columns: columns, spacing: 16) {
                metricCard(
                    L10n.text("ui.metric.battery"),
                    snapshot.batteryLevel.map(Formatters.percent) ?? L10n.text("common.none"),
                    detail: L10n.text("ui.detail.batteryPack"),
                    systemImage: "battery.100"
                )
                metricCard(
                    L10n.text("ui.metric.health"),
                    snapshot.chargeHealthPercent.map(Formatters.percent) ?? L10n.text("common.none"),
                    detail: snapshot.batteryHealthSummary,
                    systemImage: "heart.fill"
                )
                metricCard(
                    L10n.text("ui.metric.cycles"),
                    snapshot.cycleCount.map(String.init) ?? L10n.text("common.none"),
                    detail: snapshot.designCycleCount.map { L10n.tr("ui.metric.designTarget", $0) } ?? L10n.text("ui.metric.cycleTargetUnknown"),
                    systemImage: "repeat"
                )
                metricCard(
                    L10n.text("ui.metric.batteryTemp"),
                    snapshot.batteryTemperatureC.map(Formatters.temperature) ?? L10n.text("common.none"),
                    detail: L10n.tr("ui.metric.thermalStateDetail", L10n.localizedThermalState(snapshot.thermalState)),
                    systemImage: "thermometer.medium"
                )
            }

            LazyVGrid(columns: columns, spacing: 16) {
                detailCard(title: L10n.text("ui.detail.batteryPack"), rows: TelemetryDetailRows.batteryPack(snapshot))
                detailCard(title: L10n.text("ui.detail.batteryFlow"), rows: TelemetryDetailRows.batteryFlow(snapshot))
                detailCard(title: L10n.text("ui.section.batterySnapshot"), rows: TelemetryDetailRows.batterySnapshot(snapshot))
            }
        }
    }

    private func diagnosticsSection(_ snapshot: TelemetrySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            diagnosticsBlock

            if !store.topEnergyApps.isEmpty {
                EnergyUsageCard(apps: store.topEnergyApps)
            }

            LazyVGrid(columns: columns, spacing: 16) {
                detailCard(title: L10n.text("ui.section.batterySnapshot"), rows: TelemetryDetailRows.batterySnapshot(snapshot))
                detailCard(title: L10n.text("ui.section.powerSnapshot"), rows: TelemetryDetailRows.powerSnapshot(snapshot))
            }
        }
    }

    private var diagnosticsBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("ui.section.diagnostics"))
                .font(.title2.weight(.semibold))

            ForEach(store.diagnostics) { item in
                DiagnosticRow(item: item)
            }
        }
    }

    private func metricCard(_ title: String, _ value: String, detail: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .padding(18)
        .cardSurface(cornerRadius: CornerRadius.xLarge)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value). \(detail)")
    }

    private func detailCard(title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                VStack(spacing: 0) {
                    HStack {
                        Text(row.0)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(row.1)
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                    }

                    if index < rows.count - 1 {
                        Divider()
                            .padding(.top, 12)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .cardSurface(cornerRadius: CornerRadius.xLarge)
    }
}
