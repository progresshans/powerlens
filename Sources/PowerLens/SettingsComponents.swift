import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case data
    case updates

    var id: String { rawValue }

    init(storedRawValue: String) {
        if let pane = Self(rawValue: storedRawValue) {
            self = pane
            return
        }

        switch storedRawValue {
        case "behavior":
            self = .general
        case "telemetry", "history":
            self = .data
        default:
            self = .general
        }
    }

    var title: String {
        switch self {
        case .general:
            L10n.text("settings.pane.general")
        case .data:
            L10n.text("settings.pane.data")
        case .updates:
            L10n.text("settings.pane.updates")
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        case .data:
            "waveform.path.ecg"
        case .updates:
            "arrow.down.circle"
        }
    }
}

struct StatusChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.background.opacity(0.72), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.quaternary.opacity(0.6), lineWidth: 0.8)
            }
    }
}

struct LiveDot: View {
    let color: Color

    init(color: Color = .green) {
        self.color = color
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.45), radius: 3)
    }
}

/// Menu bar style choices shown as small previews of the actual readout.
struct MenuBarStylePicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 10) {
            ForEach(MenuBarDisplayStylePreference.allCases) { style in
                option(style)
            }
        }
    }

    private func option(_ style: MenuBarDisplayStylePreference) -> some View {
        let isSelected = selection == style.rawValue

        return Button {
            selection = style.rawValue
        } label: {
            VStack(spacing: 8) {
                preview(style)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(style.title)
                    .font(.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .padding(8)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(style.detail)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func preview(_ style: MenuBarDisplayStylePreference) -> some View {
        let sample = "64% · 18W"
        switch style {
        case .powerLens:
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                Text(sample)
            }
        case .powerText:
            Text(sample)
        case .nativeBattery:
            HStack(spacing: 4) {
                Text("64%")
                glyph
            }
        case .nativeBatteryOnly:
            glyph
        }
    }

    private var glyph: some View {
        Image(nsImage: MenuBarStatusItemRenderer.batteryImage(level: 65, badge: .chargingBolt))
            .renderingMode(.template)
    }
}
