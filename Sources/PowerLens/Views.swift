import SwiftUI

/// The menu bar popover. Reads top to bottom as answer → evidence →
/// interpretation → action: status sentence, proportional flow, tiles, an
/// optional notice, the heaviest app, the energy mode, then details on demand.
struct MenuBarRootView: View {
    @ObservedObject var store: PowerLensStore
    let openDashboard: () -> Void
    let openSettings: () -> Void
    let quitApplication: () -> Void
    let maxContentHeight: CGFloat?
    @ObservedObject var detailsState: PopoverDetailsState
    /// Runs a layout change while the popover animates to the new height.
    var animateResize: (() -> Void) -> Void = { change in change() }
    /// Receives the content's full height, which sizes the popover.
    var onContentHeightChange: (CGFloat) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let sectionSpacing: CGFloat = 10

    static let loadingSize = CGSize(width: 360, height: 300)
    static let contentWidth: CGFloat = 360

    var body: some View {
        Group {
            if let snapshot = store.latest, let presentation = store.live.presentation {
                Group {
                    if maxContentHeight != nil {
                        ScrollView {
                            popoverContent(snapshot, presentation: presentation)
                        }
                    } else {
                        popoverContent(snapshot, presentation: presentation)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: Self.contentWidth)
            } else {
                placeholderContent
                    .frame(width: Self.loadingSize.width, height: Self.loadingSize.height, alignment: .top)
            }
        }
        // Pinned to the top so the content never shifts while the popover
        // height is between sizes.
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Live content

    private func popoverContent(_ snapshot: TelemetrySnapshot, presentation: LivePowerPresentation) -> some View {
        let isAwaitingNewSource = presentation.isAwaitingSource
        let status = presentation.status
        let notice = presentation.notice

        return VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            header(capsule: StatusCapsule(title: status.capsuleTitle, systemImage: status.capsuleSymbol, tone: status.tone))

            hero(title: status.title, subtitle: status.subtitle)

            PowerFlowRibbonDiagram(
                graph: presentation.graph,
                style: .compact,
                batteryLevel: snapshot.batteryLevel,
                tooltip: presentation.tooltip
            )
            .padding(14)
            .glassCardSurface(cornerRadius: 16)
            .opacity(isAwaitingNewSource ? 0.4 : 1)

            HStack(spacing: 8) {
                MetricTile(
                    tile: presentation.battery,
                    symbolTint: snapshot.lowPowerModeEnabled ? LensPalette.lowPower : nil
                )
                MetricTile(tile: presentation.health)
                MetricTile(tile: presentation.temperature)
            }
            .opacity(isAwaitingNewSource ? 0.4 : 1)

            if let notice {
                NoticeCard(notice: notice)
            }

            if !store.topEnergyApps.isEmpty {
                TopEnergyAppsCard(apps: store.topEnergyApps)
            }

            if let energyMode = store.energyMode {
                EnergyModeRow(mode: energyMode)
            }

            // One block, so the drawer's spacing closes along with it.
            VStack(alignment: .leading, spacing: 0) {
                detailsDrawer(snapshot)
                footer
            }
        }
        .padding(12)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onContentHeightChange($0) }
    }

    /// Always laid out. Opening animates its height up from zero, so the
    /// details are uncovered in place while the footer moves with the edge.
    private func detailsDrawer(_ snapshot: TelemetrySnapshot) -> some View {
        details(snapshot)
            .padding(.bottom, Self.sectionSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: detailsState.isExpanded ? nil : 0, alignment: .top)
            .clipped()
            .opacity(detailsState.isExpanded ? 1 : 0)
            .accessibilityHidden(!detailsState.isExpanded)
    }

    private func header(capsule: StatusCapsule) -> some View {
        HStack(spacing: 6) {
            capsule
            Spacer(minLength: 8)
            toolbar
        }
    }

    private var toolbar: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                GlassCircleButton(
                    systemImage: "arrow.clockwise",
                    title: L10n.text("ui.refreshNow"),
                    action: store.refreshNow
                )
                GlassCircleButton(
                    systemImage: "macwindow",
                    title: L10n.text("ui.openDashboard"),
                    action: openDashboard
                )
                Menu {
                    Button(L10n.text("menu.settings"), action: openSettings)
                        .keyboardShortcut(",")
                    Divider()
                    Button(L10n.text("menu.quit"), action: quitApplication)
                        .keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .fixedSize()
                .help(L10n.text("ui.more"))
                .accessibilityLabel(L10n.text("ui.more"))
            }
        }
    }

    private func hero(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    private func details(_ snapshot: TelemetrySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailGroupCard(title: L10n.text("flow.node.battery"), rows: TelemetryDetailRows.popoverBattery(snapshot))

            if snapshot.externalConnected {
                DetailGroupCard(title: L10n.text("flow.node.charger"), rows: TelemetryDetailRows.popoverCharger(snapshot))
            }

            if snapshot.batteryPowerIsDerived {
                Text(L10n.text("ui.detail.approximateFootnote"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button(action: toggleDetails) {
                HStack(spacing: 4) {
                    // Swapped in place: a crossfade would draw the new title at
                    // the footer's final position while the footer moves.
                    Text(L10n.text(detailsState.isExpanded ? "ui.details.hide" : "ui.details.show"))
                        .contentTransition(.identity)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(detailsState.isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            FreshnessLabel(
                refreshDate: store.lastRefreshAt ?? store.latest?.timestamp,
                health: store.telemetryHealth
            )
        }
        .padding(.horizontal, 4)
    }

    private func toggleDetails() {
        if reduceMotion {
            detailsState.isExpanded.toggle()
        } else {
            animateResize { detailsState.isExpanded.toggle() }
        }
    }

    // MARK: - Waiting and unavailable

    @ViewBuilder
    private var placeholderContent: some View {
        if store.telemetryUnavailable {
            VStack(alignment: .leading, spacing: 10) {
                header(capsule: StatusCapsule(
                    title: L10n.text("capsule.unavailable"),
                    systemImage: "exclamationmark.circle",
                    tone: .neutral
                ))
                hero(
                    title: L10n.text("ui.telemetryUnavailable.title"),
                    subtitle: L10n.text("ui.telemetryUnavailable.message")
                )
                NoticeCard(notice: PowerNotice(
                    tone: .charger,
                    symbol: "gearshape.fill",
                    title: L10n.text("notice.unavailable.title"),
                    message: L10n.text("notice.unavailable.message")
                ))
                HStack(spacing: 8) {
                    Button(action: openSettings) {
                        Text(L10n.text("notice.unavailable.openSettings")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    Button(action: store.refreshNow) {
                        Text(L10n.text("notice.unavailable.retry")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.large)
            }
            .padding(12)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                header(capsule: StatusCapsule(
                    title: L10n.text("capsule.reading"),
                    systemImage: "ellipsis",
                    tone: .neutral
                ))
                hero(title: L10n.text("ui.readingPowerData"), subtitle: L10n.text("ui.readingPowerData.hint"))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 120)
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .frame(height: 62)
                    }
                }
            }
            .padding(12)
        }
    }
}

/// "방금 업데이트" while values are live, "12초 전 값" in orange when stale.
private struct FreshnessLabel: View {
    let refreshDate: Date?
    let health: TelemetryHealth

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let freshness = TelemetryFreshness(refreshDate: refreshDate, health: health, now: context.date)
            Text(freshness.updatedText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(style(freshness))
        }
    }

    private func style(_ freshness: TelemetryFreshness) -> AnyShapeStyle {
        switch freshness.state {
        case .waiting, .live:
            AnyShapeStyle(.tertiary)
        case .delayed:
            AnyShapeStyle(freshness.isCriticallyDelayed ? LensPalette.warning : LensPalette.caution)
        case .unavailable:
            AnyShapeStyle(LensPalette.warning)
        }
    }
}
