import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case telemetry
    case history
    case behavior

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            L10n.text("settings.pane.general")
        case .telemetry:
            L10n.text("settings.pane.telemetry")
        case .history:
            L10n.text("settings.pane.history")
        case .behavior:
            L10n.text("settings.pane.behavior")
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        case .telemetry:
            "waveform.path.ecg"
        case .history:
            "clock.arrow.circlepath"
        case .behavior:
            "macwindow"
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
    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: 8, height: 8)
            .shadow(color: .green.opacity(0.45), radius: 3)
    }
}
