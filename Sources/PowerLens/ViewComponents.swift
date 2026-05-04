import AppKit
import SwiftUI

struct ForegroundAppCard: View {
    let snapshot: TelemetrySnapshot

    private var displayName: String {
        snapshot.frontmostAppName ?? snapshot.frontmostAppBundleID ?? L10n.text("ui.highEnergyApp.unknown")
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(L10n.text("ui.highEnergyApp.label"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 10)

            AppBadge(bundleIdentifier: snapshot.frontmostAppBundleID, name: displayName)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct AppBadge: View {
    let bundleIdentifier: String?
    let name: String

    private var appIcon: NSImage? {
        AppIconCache.icon(for: bundleIdentifier)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            Text(name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.background.opacity(0.72), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.quaternary.opacity(0.6))
        )
    }
}

@MainActor
private enum AppIconCache {
    private static var iconsByBundleIdentifier: [String: NSImage] = [:]
    private static var missingBundleIdentifiers: Set<String> = []

    static func icon(for bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return nil
        }

        if let icon = iconsByBundleIdentifier[bundleIdentifier] {
            return icon
        }

        guard !missingBundleIdentifiers.contains(bundleIdentifier) else {
            return nil
        }

        if let icon = runningApplicationIcon(for: bundleIdentifier) ?? installedApplicationIcon(for: bundleIdentifier) {
            iconsByBundleIdentifier[bundleIdentifier] = icon
            return icon
        }

        missingBundleIdentifiers.insert(bundleIdentifier)
        return nil
    }

    private static func runningApplicationIcon(for bundleIdentifier: String) -> NSImage? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.icon
    }

    private static func installedApplicationIcon(for bundleIdentifier: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }

        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

struct CompactDetailCard: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.0)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 10)
                        Text(row.1)
                            .fontWeight(.semibold)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.caption)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.26), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct DiagnosticRow: View {
    let item: DiagnosticItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                Text(item.title)
                    .font(.headline)
            }
            Text(item.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var color: Color {
        switch item.severity {
        case .info:
            .blue
        case .caution:
            .orange
        case .warning:
            .red
        }
    }
}

struct LiveIndicatorView: View {
    let refreshDate: Date?
    let activeEngineName: String

    var body: some View {
        let now = Date()

        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(dotColor(now: now).opacity(isLive(now: now) ? 0.16 : 0.08))
                    .frame(width: 22, height: 22)

                Circle()
                    .fill(dotColor(now: now))
                    .frame(width: 10, height: 10)
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("telemetry.live"))
                    .font(.subheadline.weight(.semibold))

                Text(detailText(now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func detailText(now: Date) -> String {
        guard let refreshDate else {
            return L10n.text("telemetry.live.waiting")
        }

        return L10n.tr("telemetry.live.detail", activeEngineName, Formatters.relativeAge(since: refreshDate, now: now))
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

    private func isLive(now: Date) -> Bool {
        guard let refreshDate else {
            return false
        }

        return now.timeIntervalSince(refreshDate) <= 6
    }
}
