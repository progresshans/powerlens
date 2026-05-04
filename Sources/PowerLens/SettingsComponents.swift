import SwiftUI

enum SettingsLayout {
    static let groupMaxWidth: CGFloat = 760
    static let rowHorizontalPadding: CGFloat = 16
    static let rowColumnSpacing: CGFloat = 18
    static let controlColumnWidth: CGFloat = 300
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case telemetry
    case behavior

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            L10n.text("settings.pane.general")
        case .telemetry:
            L10n.text("settings.pane.telemetry")
        case .behavior:
            L10n.text("settings.pane.behavior")
        }
    }

    var subtitle: String {
        switch self {
        case .general:
            L10n.text("settings.pane.general.description")
        case .telemetry:
            L10n.text("settings.pane.telemetry.description")
        case .behavior:
            L10n.text("settings.pane.behavior.description")
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        case .telemetry:
            "waveform.path.ecg"
        case .behavior:
            "macwindow"
        }
    }
}

struct SettingsHeader: View {
    let pane: SettingsPane

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: pane.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .adaptiveGlassBackground(in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(pane.title)
                    .font(.title3.weight(.semibold))

                Text(pane.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }
}

struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(maxWidth: SettingsLayout.groupMaxWidth, alignment: .leading)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.quaternary.opacity(0.45), lineWidth: 0.8)
        }
    }
}

struct PreferenceRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        SettingsRowShell {
            SettingsRowLabel(title: title, detail: detail)
        } control: {
            control()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct ValueRow: View {
    let title: String
    let detail: String
    let value: String

    var body: some View {
        SettingsRowShell {
            SettingsRowLabel(title: title, detail: detail)
        } control: {
            Text(value)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct SettingsRowShell<LabelContent: View, ControlContent: View>: View {
    @ViewBuilder let label: () -> LabelContent
    @ViewBuilder let control: () -> ControlContent

    var body: some View {
        HStack(alignment: .center, spacing: SettingsLayout.rowColumnSpacing) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            control()
                .frame(width: SettingsLayout.controlColumnWidth, alignment: .trailing)
        }
        .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
        .padding(.vertical, 14)
        .frame(minHeight: 72)
    }
}

struct MenuBarDisplayStyleMenu: View {
    @Binding var selection: String

    private var selectedStyle: MenuBarDisplayStylePreference {
        MenuBarDisplayStylePreference(rawValue: selection) ?? .powerLens
    }

    var body: some View {
        Menu {
            ForEach(MenuBarDisplayStylePreference.allCases) { style in
                Button {
                    selection = style.rawValue
                } label: {
                    HStack {
                        Text(style.title)
                        if style == selectedStyle {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selectedStyle.title)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.body)
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(width: 220, height: 30)
            .background(.quaternary.opacity(0.34), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(width: 220)
        .accessibilityLabel(L10n.text("menuBarStyle.title"))
        .accessibilityValue(selectedStyle.title)
    }
}

struct SettingsRowLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .foregroundStyle(.primary)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TelemetryStatusRow: View {
    let title: String
    let statusText: String
    let activeEngineName: String

    var body: some View {
        SettingsRowShell {
            HStack(spacing: 12) {
                LiveDot()

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))

                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } control: {
            StatusChip(text: activeEngineName)
                .frame(maxWidth: .infinity, alignment: .trailing)
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

struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, SettingsLayout.rowHorizontalPadding)
    }
}

private struct AdaptiveGlassBackground<S: Shape>: ViewModifier {
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(.quaternary.opacity(0.26), in: shape)
                .overlay {
                    shape
                        .stroke(.quaternary.opacity(0.5), lineWidth: 0.8)
                }
        }
    }
}

extension View {
    func adaptiveGlassBackground<S: Shape>(in shape: S) -> some View {
        modifier(AdaptiveGlassBackground(shape: shape))
    }
}
