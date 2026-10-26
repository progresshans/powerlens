import Charts
import SwiftUI

/// Three places to go. "지금" already answers what the old Dashboard, Power
/// Flow, and Diagnostics screens each answered in part.
enum DashboardSidebarDestination: String, CaseIterable, Identifiable {
    case dashboard
    case battery
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:
            L10n.text("ui.sidebar.dashboard")
        case .battery:
            L10n.text("ui.sidebar.battery")
        case .history:
            L10n.text("ui.sidebar.history")
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard:
            "gauge.with.dots.needle.67percent"
        case .battery:
            "battery.100percent"
        case .history:
            "chart.xyaxis.line"
        }
    }
}

struct SidebarFooterAction: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(
            Color.primary.opacity(isHovered ? 0.08 : 0),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Colored key for a flow or chart series.
struct LegendItem: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A window card with an icon + label header, a big number, an optional
/// visual, and a one-line interpretation.
struct DashboardMetricCard<Visual: View>: View {
    let title: String
    let systemImage: String
    let iconTint: Color
    let value: String
    var unit: String?
    var trailingNote: String?
    let caption: String
    @ViewBuilder var visual: () -> Visual

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(iconTint)
                Text(title)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let trailingNote {
                    Text(trailingNote)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                }
            }

            visual()

            Text(caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }
}

/// A list row for "알아두면 좋아요".
struct InsightRow: View {
    let systemImage: String
    let tint: Color
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// The last hour of input and Mac power from the in-memory trace.
struct RecentPowerChart: View {
    let samples: [RecentPowerSample]
    var showsInput = true
    var compact = false

    /// The full chart always spans the hour its title promises, so a fresh
    /// trace fills in from the right; the sparkline fits whatever it has.
    private var timeDomain: ClosedRange<Date> {
        let end = samples.last?.date ?? Date()
        guard compact, let start = samples.first?.date, start < end else {
            return end.addingTimeInterval(-RecentPowerSample.window)...end
        }
        return start...end
    }

    /// Wall-clock quarter hours, kept clear of both edges so no label clips.
    private var quarterHourTicks: [Date] {
        let domain = timeDomain
        let quarter: TimeInterval = 15 * 60
        let margin: TimeInterval = 4 * 60
        var tick = (domain.lowerBound.timeIntervalSinceReferenceDate / quarter).rounded(.up) * quarter
        var ticks: [Date] = []
        while tick <= domain.upperBound.timeIntervalSinceReferenceDate - margin {
            if tick >= domain.lowerBound.timeIntervalSinceReferenceDate + margin {
                ticks.append(Date(timeIntervalSinceReferenceDate: tick))
            }
            tick += quarter
        }
        return ticks
    }

    var body: some View {
        Chart {
            if showsInput {
                ForEach(samples) { sample in
                    if let input = sample.inputW {
                        AreaMark(
                            x: .value("time", sample.date),
                            y: .value("input", input),
                            series: .value("series", "input-area")
                        )
                        .foregroundStyle(LensPalette.charger.opacity(0.16))
                        .interpolationMethod(.monotone)
                        LineMark(
                            x: .value("time", sample.date),
                            y: .value("input", input),
                            series: .value("series", "input")
                        )
                        .foregroundStyle(LensPalette.charger)
                        .interpolationMethod(.monotone)
                    }
                }
            }
            ForEach(samples) { sample in
                if let system = sample.systemW {
                    LineMark(
                        x: .value("time", sample.date),
                        y: .value("mac", system),
                        series: .value("series", "mac")
                    )
                    .foregroundStyle(LensPalette.mac)
                    .interpolationMethod(.monotone)
                }
            }
        }
        .chartXScale(domain: timeDomain)
        .chartXAxis {
            if !compact {
                AxisMarks(values: quarterHourTicks) {
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
        }
        .chartYAxis(compact ? .hidden : .automatic)
        .chartLegend(.hidden)
    }
}
