import Charts
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: PowerLensStore
    let openSettings: () -> Void
    @SceneStorage("dashboard.sidebar.selection") private var selectedDestinationRaw = DashboardSidebarDestination.dashboard.rawValue
    let session: DashboardSession

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
        .onAppear { store.setDashboardEnergyDemand(selectedDestination == .dashboard) }
        .onChange(of: selectedDestinationRaw) { store.setDashboardEnergyDemand(selectedDestination == .dashboard) }
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

            if let snapshot = store.latest, let presentation = store.live.presentation {
                sidebarStatus(snapshot, presentation: presentation)
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

    private func sidebarStatus(_ snapshot: TelemetrySnapshot, presentation: LivePowerPresentation) -> some View {
        let status = presentation.status
        let battery = presentation.battery
        let mac = presentation.readings.systemPower?.formatted ?? L10n.text("common.none")

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
                        if let snapshot = store.latest, let presentation = store.live.presentation {
                            DashboardNowPage(snapshot: snapshot, presentation: presentation,
                                live: store.live, energyApps: store.topEnergyApps,
                                historyRevision: store.historyRevision, refresh: store.refreshNow,
                                loadRecent: store.recentPowerHistory, recentHistory: session.recentHistory)
                        }
                    case .battery:
                        if let snapshot = store.latest {
                            DashboardBatteryPage(snapshot: snapshot)
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
            InsightsView(store: store, model: session.insights, exportState: session.exportState)
        }
    }

}
