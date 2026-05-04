import SwiftUI

enum PowerFlowCardDensity {
    case regular
    case compact

    var cardPadding: CGFloat {
        switch self {
        case .regular:
            13
        case .compact:
            11
        }
    }

    var panelPadding: CGFloat {
        switch self {
        case .regular:
            11
        case .compact:
            9
        }
    }

    var rowSpacing: CGFloat {
        switch self {
        case .regular:
            9
        case .compact:
            7
        }
    }
}

struct PowerFlowCard: View {
    let snapshot: TelemetrySnapshot
    let density: PowerFlowCardDensity

    init(snapshot: TelemetrySnapshot, density: PowerFlowCardDensity = .regular) {
        self.snapshot = snapshot
        self.density = density
    }

    var body: some View {
        let model = PowerFlowPresentationModel(snapshot: snapshot)
        let stateTint = DistributionPalette.tint(for: model.state.tintRole)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("ui.section.flow"))
                    .font(.headline)

                Spacer()

                Text(model.state.localizedTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(stateTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(stateTint.opacity(0.12), in: Capsule())
            }

            BatteryLevelStrip(
                level: snapshot.batteryLevel,
                isCharging: snapshot.isBatteryChargingForDisplay,
                isCharged: snapshot.isCharged
            )

            PowerDistributionPanel(
                rows: model.routes,
                density: density
            )
        }
        .padding(density.cardPadding)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct PowerDistributionPanel: View {
    let rows: [PowerFlowRouteModel]
    let density: PowerFlowCardDensity

    var body: some View {
        VStack(alignment: .leading, spacing: density.rowSpacing) {
            PowerDistributionDiagram(rows: rows, density: density)
        }
        .padding(density.panelPadding)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background.opacity(0.60))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.8)
        }
    }
}

private struct BatteryLevelStrip: View {
    let level: Double?
    let isCharging: Bool
    let isCharged: Bool

    private var shouldShowFill: Bool {
        PowerFlowBatteryLevelStripLayout.shouldShowFill(level)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text("ui.metric.battery"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(level.map(Formatters.percent) ?? L10n.text("common.none"))
                    .font(.caption.weight(.semibold))
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary.opacity(0.35))

                    if shouldShowFill {
                        Capsule()
                            .fill(levelTint)
                            .frame(width: PowerFlowBatteryLevelStripLayout.fillWidth(
                                level: level,
                                trackWidth: proxy.size.width
                            ))
                    }
                }
            }
            .frame(height: 16)
        }
    }

    private var levelTint: LinearGradient {
        if isCharged {
            return LinearGradient(colors: [.green.opacity(0.85), .green], startPoint: .leading, endPoint: .trailing)
        }

        if isCharging {
            return LinearGradient(colors: [.blue.opacity(0.9), .cyan.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
        }

        return LinearGradient(colors: [.blue.opacity(0.8), .blue.opacity(0.6)], startPoint: .leading, endPoint: .trailing)
    }
}

enum PowerFlowBatteryLevelStripLayout {
    static func clampedLevel(_ level: Double?) -> Double {
        min(max(level ?? 0, 0), 100)
    }

    static func shouldShowFill(_ level: Double?) -> Bool {
        level != nil && clampedLevel(level) > 0
    }

    static func fillWidth(level: Double?, trackWidth: CGFloat) -> CGFloat {
        guard shouldShowFill(level), trackWidth > 0 else {
            return 0
        }

        return trackWidth * CGFloat(clampedLevel(level) / 100)
    }
}
