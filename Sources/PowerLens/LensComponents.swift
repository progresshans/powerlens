import AppKit
import SwiftUI

extension StatusTone {
    var tint: Color {
        switch self {
        case .charging: LensPalette.battery
        case .charger: LensPalette.charger
        case .caution: LensPalette.caution
        case .warning: LensPalette.warning
        case .neutral: .secondary
        }
    }

    var softFill: Color {
        switch self {
        case .neutral: Color.primary.opacity(0.08)
        default: tint.opacity(0.16)
        }
    }

    /// Caption color under a metric. Neutral captions stay secondary.
    var captionStyle: AnyShapeStyle {
        self == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint)
    }
}

/// SF Symbol plus a two-word state. Only the symbol carries the hue.
struct StatusCapsule: View {
    let title: String
    let systemImage: String
    let tone: StatusTone

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tone.tint)
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .padding(.vertical, 3)
        .background(tone.softFill, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Label → number → interpretation.
struct MetricTile: View {
    let tile: MetricTilePresentation
    var symbolTint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: tile.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(symbolTint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                Text(tile.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(tile.value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(tile.caption)
                .font(.caption)
                .foregroundStyle(tile.captionTone.captionStyle)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCardSurface()
        .accessibilityElement(children: .combine)
    }
}

/// What happened, and what to try. Tinted with the tone it reports.
struct NoticeCard: View {
    let notice: PowerNotice

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: notice.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(notice.tone.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(notice.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(notice.tone.softFill, in: RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// macOS 26 circular glass button with a tooltip.
struct GlassCircleButton: View {
    let systemImage: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// "에너지를 많이 사용하는 앱": up to three apps, most demanding first.
/// Read-only; it names the apps and leaves the rest to the person.
struct TopEnergyAppsCard: View {
    static let maximumApps = 3

    let apps: [AppEnergyUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.text("ui.highEnergyApp.label"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(apps.prefix(Self.maximumApps)) { app in
                HStack(spacing: 8) {
                    if let icon = AppIconCache.icon(forPath: app.appPath) {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 16, height: 16)
                    }
                    Text(app.name)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCardSurface()
        .accessibilityElement(children: .combine)
    }
}

/// Shows the current energy mode and opens Battery settings to change it.
/// Changing the mode needs administrator rights, so PowerLens hands it to
/// System Settings instead of pretending to be a switch.
struct EnergyModeRow: View {
    let mode: EnergyMode

    var body: some View {
        Button(action: EnergyModeSettings.open) {
            HStack(spacing: 10) {
                Image(systemName: "battery.75percent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(mode == .lowPower ? AnyShapeStyle(LensPalette.lowPower) : AnyShapeStyle(.secondary))
                    .frame(width: 22, height: 22)
                    .background(
                        mode == .lowPower ? LensPalette.lowPower.opacity(0.2) : Color.primary.opacity(0.08),
                        in: Circle()
                    )
                Text(mode.rowTitle)
                    .fontWeight(.medium)
                Spacer(minLength: 8)
                Text(mode.valueText)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassCardSurface()
        .help(L10n.text("energyMode.openSettings"))
        .accessibilityLabel("\(mode.rowTitle), \(mode.valueText)")
    }
}

/// A titled group of label/value rows separated by hairlines.
struct DetailGroupCard: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            DetailRows(rows: rows, style: .popover)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .glassCardSurface()
        }
    }
}

/// A rounded gauge with an optional reference mark (e.g. a charge limit).
struct BarGauge: View {
    /// Nil when the value is unknown: only the track is drawn, so a missing
    /// reading never looks like zero.
    let fraction: Double?
    let tint: Color
    var marker: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fillWidth = GaugeLayout.fillWidth(fraction: fraction, trackWidth: width)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if fillWidth > 0 {
                    Capsule()
                        .fill(tint)
                        .frame(width: fillWidth)
                }
                if let marker {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.secondary)
                        .frame(width: 2, height: 14)
                        .offset(x: width * min(max(marker, 0), 1) - 1)
                }
            }
        }
        .frame(height: 8)
    }
}

@MainActor
enum AppIconCache {
    private static var iconsByPath: [String: NSImage] = [:]

    static func icon(forPath path: String) -> NSImage? {
        if let cached = iconsByPath[path] {
            return cached
        }

        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: path)
        iconsByPath[path] = icon
        return icon
    }
}
