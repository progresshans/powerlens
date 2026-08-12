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
