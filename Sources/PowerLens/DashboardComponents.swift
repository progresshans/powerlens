import SwiftUI

enum DashboardSidebarDestination: String, CaseIterable, Identifiable {
    case dashboard
    case power
    case battery
    case diagnostics
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:
            L10n.text("ui.sidebar.dashboard")
        case .power:
            L10n.text("ui.sidebar.power")
        case .battery:
            L10n.text("ui.sidebar.battery")
        case .diagnostics:
            L10n.text("ui.sidebar.diagnostics")
        case .history:
            L10n.text("ui.sidebar.history")
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard:
            "square.grid.2x2"
        case .power:
            "bolt.fill"
        case .battery:
            "battery.100"
        case .diagnostics:
            "waveform.path.ecg"
        case .history:
            "chart.xyaxis.line"
        }
    }

    var detailTitle: String {
        switch self {
        case .dashboard:
            L10n.text("ui.sidebar.dashboard")
        case .power:
            L10n.text("ui.sidebar.power")
        case .battery:
            L10n.text("ui.sidebar.battery")
        case .diagnostics:
            L10n.text("ui.sidebar.diagnostics")
        case .history:
            L10n.text("ui.sidebar.history")
        }
    }
}

struct DashboardHeaderAction: View {
    let systemImage: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.quaternary.opacity(0.42), lineWidth: 0.8)
        }
        .help(title)
        .accessibilityLabel(title)
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
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(
            .quaternary.opacity(isHovered ? 0.26 : 0),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}
