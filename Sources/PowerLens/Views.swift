import SwiftUI

struct MenuBarRootView: View {
    @ObservedObject var store: PowerLensStore
    let openDashboard: () -> Void
    let openSettings: () -> Void
    let quitApplication: () -> Void
    let maxContentHeight: CGFloat?

    static let loadingSize = CGSize(width: 320, height: 260)
    static let contentWidth: CGFloat = 420

    var body: some View {
        Group {
            if let snapshot = store.latest {
                popoverContent(snapshot)
                    .modifier(PopoverContainerStyle(maxContentHeight: maxContentHeight))
                    .frame(width: Self.contentWidth, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: maxContentHeight == nil)
            } else {
                VStack(spacing: 0) {
                    Group {
                        if store.telemetryUnavailable {
                            VStack(spacing: 10) {
                                Image(systemName: "bolt.slash")
                                    .font(.title)
                                    .foregroundStyle(.secondary)
                                Text(L10n.text("ui.telemetryUnavailable.title"))
                                    .font(.headline)
                                    .multilineTextAlignment(.center)
                                Text(L10n.text("ui.telemetryUnavailable.message"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(24)
                        } else {
                            ProgressView(L10n.text("ui.readingPowerData"))
                                .padding(24)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()
                    HStack {
                        Spacer()
                        toolbarActions
                    }
                    .padding(12)
                }
                .frame(width: Self.loadingSize.width, height: Self.loadingSize.height)
            }
        }
    }

    private func popoverContent(_ snapshot: TelemetrySnapshot) -> some View {
        let diagnostics = snapshot.diagnosticsExcludingPrimaryStatus(
            store.diagnostics,
            resolvedState: store.resolvedPowerState
        )

        return VStack(alignment: .leading, spacing: 12) {
            popoverHeader(snapshot)

            PowerFlowCard(snapshot: snapshot, density: .compact)

            if !diagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("ui.section.diagnostics"))
                        .font(.subheadline.weight(.semibold))

                    ForEach(diagnostics.prefix(2)) { item in
                        DiagnosticRow(item: item)
                    }
                }
            }

            if !store.topEnergyApps.isEmpty {
                EnergyUsageCard(apps: store.topEnergyApps)
            }

            CompactDetailCard(
                title: L10n.text("ui.section.batterySnapshot"),
                rows: TelemetryDetailRows.batterySnapshot(snapshot)
            )

            CompactDetailCard(
                title: L10n.text("ui.section.powerSnapshot"),
                rows: TelemetryDetailRows.powerSnapshot(snapshot)
            )
        }
        .padding(12)
    }

    private func popoverHeader(_ snapshot: TelemetrySnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(
                    snapshot.statusHeadline(
                        resolvedState: store.resolvedPowerState
                    )
                )
                    .font(.headline)
                    .lineLimit(2)

                Text(
                    snapshot.statusSubheadline(
                        resolvedState: store.resolvedPowerState
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                CompactLiveStatusChip(
                    refreshDate: store.lastRefreshAt ?? snapshot.timestamp,
                    health: store.telemetryHealth
                )

                toolbarActions
            }
        }
    }

    private var toolbarActions: some View {
        HStack(spacing: 5) {
            PopoverToolbarButton(
                systemImage: "arrow.clockwise",
                title: L10n.text("ui.refreshNow"),
                action: store.refreshNow
            )

            PopoverToolbarButton(
                systemImage: "gearshape",
                title: L10n.text("ui.section.settings"),
                action: openSettings
            )

            PopoverToolbarButton(
                systemImage: "square.grid.2x2",
                title: L10n.text("ui.openDashboard"),
                action: openDashboard
            )

            PopoverToolbarButton(
                systemImage: "power",
                title: L10n.text("common.quit"),
                action: quitApplication
            )
        }
    }
}

private struct CompactLiveStatusChip: View {
    let refreshDate: Date?
    let health: TelemetryHealth

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let freshness = TelemetryFreshness(
            refreshDate: refreshDate,
            health: health,
            now: now
        )

        return HStack(spacing: 5) {
            Circle()
                .fill(dotColor(freshness))
                .frame(width: 7, height: 7)
                .shadow(
                    color: dotColor(freshness).opacity(0.35),
                    radius: 2
                )

            Text(detailText(freshness, now: now))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.24), in: Capsule())
    }

    private func detailText(
        _ freshness: TelemetryFreshness,
        now: Date
    ) -> String {
        guard let refreshDate else {
            return "\(freshness.title) · \(L10n.text("telemetry.live.waiting"))"
        }

        return "\(freshness.title) · \(Formatters.relativeAge(since: refreshDate, now: now))"
    }

    private func dotColor(_ freshness: TelemetryFreshness) -> Color {
        switch freshness.state {
        case .waiting:
            return .gray
        case .unavailable:
            return .red
        case .delayed:
            return freshness.isCriticallyDelayed ? .red : .orange
        case .live:
            return .green
        }
    }
}

private struct PopoverToolbarButton: View {
    let systemImage: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 27, height: 27)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(.quaternary.opacity(0.26), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.quaternary.opacity(0.48), lineWidth: 0.8)
        }
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct PopoverContainerStyle: ViewModifier {
    let maxContentHeight: CGFloat?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let maxContentHeight {
            ScrollView {
                content
            }
            .frame(maxHeight: maxContentHeight)
        } else {
            content
        }
    }
}
