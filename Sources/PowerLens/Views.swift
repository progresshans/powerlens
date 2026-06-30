import SwiftUI

struct MenuBarRootView: View {
    @ObservedObject var store: PowerLensStore
    let openDashboard: () -> Void
    let openSettings: () -> Void
    let quitApplication: () -> Void
    let maxContentHeight: CGFloat?

    static let loadingSize = CGSize(width: 320, height: 220)
    static let contentWidth: CGFloat = 420

    var body: some View {
        Group {
            if let snapshot = store.latest {
                popoverContent(snapshot)
                    .modifier(PopoverContainerStyle(maxContentHeight: maxContentHeight))
                    .frame(width: Self.contentWidth, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: maxContentHeight == nil)
            } else if store.telemetryUnavailable {
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
                .frame(width: Self.loadingSize.width, height: Self.loadingSize.height)
            } else {
                ProgressView(L10n.text("ui.readingPowerData"))
                    .padding(32)
                    .frame(width: Self.loadingSize.width, height: Self.loadingSize.height)
            }
        }
    }

    private func popoverContent(_ snapshot: TelemetrySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            popoverHeader(snapshot)

            PowerFlowCard(snapshot: snapshot, density: .compact)

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("ui.section.diagnostics"))
                    .font(.subheadline.weight(.semibold))

                ForEach(store.diagnostics.prefix(2)) { item in
                    DiagnosticRow(item: item)
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
                Text(snapshot.statusHeadline)
                    .font(.headline)
                    .lineLimit(2)

                Text(snapshot.statusSubheadline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                CompactLiveStatusChip(refreshDate: store.lastRefreshAt ?? snapshot.timestamp)

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
    }
}

private struct CompactLiveStatusChip: View {
    let refreshDate: Date?

    var body: some View {
        let now = Date()

        HStack(spacing: 5) {
            Circle()
                .fill(dotColor(now: now))
                .frame(width: 7, height: 7)
                .shadow(color: dotColor(now: now).opacity(0.35), radius: 2)

            Text(detailText(now: now))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.24), in: Capsule())
    }

    private func detailText(now: Date) -> String {
        guard let refreshDate else {
            return "\(L10n.text("telemetry.live")) · \(L10n.text("telemetry.live.waiting"))"
        }

        return "\(L10n.text("telemetry.live")) · \(Formatters.relativeAge(since: refreshDate, now: now))"
    }

    private func dotColor(now: Date) -> Color {
        guard let refreshDate else {
            return .gray
        }

        let age = now.timeIntervalSince(refreshDate)
        if age <= 6 {
            return .green
        }
        if age <= 15 {
            return .orange
        }
        return .red
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
