import SwiftUI

/// Shared row rendering; containers keep their existing surface and spacing.
struct DetailRows: View {
    enum Style { case popover, window }
    let rows: [(String, String)]
    let style: Style

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: style == .popover ? .firstTextBaseline : .center) {
                    Text(row.0)
                        .foregroundStyle(style == .window ? .secondary : .primary)
                    Spacer(minLength: style == .popover ? 10 : nil)
                    Text(row.1)
                        .foregroundStyle(style == .popover ? .secondary : .primary)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
                .padding(.vertical, style == .popover ? 6 : 9)
                if index < rows.count - 1 { Divider() }
            }
        }
    }
}
