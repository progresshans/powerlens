import SwiftUI

struct DashboardPageHeader: View {
    let capsule: StatusCapsule?
    let meta: (Date) -> String?
    let title: String
    let subtitle: String?
    let showsRefresh: Bool
    var refresh: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    if let capsule {
                        capsule
                    }
                    // Data refreshes redraw this every few seconds anyway; the
                    // slow tick only keeps "N초 전" honest if refreshes stall.
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        if let text = meta(context.date) {
                            Text(text)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                }
                Text(title)
                    .font(.title.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                if let subtitle {
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            if showsRefresh {
                Button(action: refresh) {
                    Label(L10n.text("ui.refresh"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
    }

}
