import Charts
import SwiftUI

struct HistoryCharts: View {
    let history: [TelemetrySnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            chartCard(
                title: L10n.text("ui.history.batteryCharge"),
                subtitle: L10n.text("ui.history.last24Hours"),
                chart: AnyView(
                    Chart(history) { point in
                        if let batteryLevel = point.batteryLevel {
                            LineMark(
                                x: .value(L10n.text("ui.history.axis.time"), point.timestamp),
                                y: .value(L10n.text("ui.history.axis.battery"), batteryLevel)
                            )
                            .foregroundStyle(.blue)

                            AreaMark(
                                x: .value(L10n.text("ui.history.axis.time"), point.timestamp),
                                y: .value(L10n.text("ui.history.axis.battery"), batteryLevel)
                            )
                            .foregroundStyle(.blue.opacity(0.12))
                        }
                    }
                    .chartYScale(domain: 0 ... 100)
                )
            )

            chartCard(
                title: L10n.text("ui.history.powerFlow"),
                subtitle: L10n.text("ui.history.inputVsLoad"),
                chart: AnyView(
                    Chart {
                        ForEach(history) { point in
                            if let input = point.adapterInputPowerW {
                                LineMark(
                                    x: .value(L10n.text("ui.history.axis.time"), point.timestamp),
                                    y: .value(L10n.text("ui.history.axis.powerIn"), input)
                                )
                                .foregroundStyle(.green)
                            }

                            if let load = point.systemLoadW {
                                LineMark(
                                    x: .value(L10n.text("ui.history.axis.time"), point.timestamp),
                                    y: .value(L10n.text("ui.history.axis.systemLoad"), load)
                                )
                                .foregroundStyle(.orange)
                            }
                        }
                    }
                )
            )
        }
    }

    private func chartCard(title: String, subtitle: String, chart: AnyView) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            chart
                .frame(height: 220)
        }
        .padding(18)
        .background(.quaternary.opacity(0.26), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
