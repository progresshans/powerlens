import AppKit
import Charts
import SwiftUI

/// The Insights screen: a selectable time range, summary statistics, and
/// interactive trend charts built from the aggregated history store data.
struct InsightsView: View {
    @ObservedObject var store: PowerLensStore
    @SceneStorage(HistoryRange.storageKey) private var selectedRangeRaw = HistoryRange.last24Hours.rawValue
    @StateObject private var model = InsightsViewModel()
    @State private var isExporting = false
    @State private var exportError: String?

    private let columns = [
        GridItem(.adaptive(minimum: 170), spacing: 14, alignment: .top),
    ]

    private var selectedRange: HistoryRange {
        HistoryRange(rawValue: selectedRangeRaw) ?? .last24Hours
    }

    private var request: InsightsRequest {
        InsightsRequest(range: selectedRange, historyRevision: store.historyRevision)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center) {
                rangePicker
                Spacer(minLength: Spacing.medium)
                exportMenu
            }

            if store.historyHealth == .degraded {
                Label(
                    L10n.text("history.status.degraded.detail"),
                    systemImage: "externaldrive.badge.exclamationmark"
                )
                .font(.callout)
                .foregroundStyle(.red)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    .red.opacity(0.08),
                    in: RoundedRectangle(
                        cornerRadius: 12,
                        style: .continuous
                    )
                )
            }

            if let data = model.data {
                if data.hasSeries {
                    summaryGrid(data.summary)
                    BatteryLevelChartCard(points: data.series)
                    PowerFlowChartCard(points: data.series)
                } else {
                    emptyState
                }

                BatteryHealthSection(trend: data.healthTrend)
            } else {
                loadingState
            }
        }
        .task(id: request) {
            await model.load(request: request, using: store.loadInsights)
        }
        .alert(
            L10n.text("insights.export.failed.title"),
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button(L10n.text("common.ok")) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var rangePicker: some View {
        Picker(L10n.text("insights.title"), selection: $selectedRangeRaw) {
            ForEach(HistoryRange.allCases) { range in
                Text(range.title).tag(range.rawValue)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 380, alignment: .leading)
        .accessibilityLabel(L10n.text("insights.title"))
    }

    private var exportMenu: some View {
        Menu {
            ForEach(HistoryExportFormat.allCases) { format in
                Button(format.title) {
                    export(format)
                }
            }
        } label: {
            HStack(spacing: 6) {
                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                }
                Label(L10n.text("insights.export"), systemImage: "square.and.arrow.up")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.data?.hasSeries != true || isExporting)
        .help(L10n.text("insights.export"))
    }

    private func export(_ format: HistoryExportFormat) {
        guard !isExporting else {
            return
        }
        let range = selectedRange
        isExporting = true
        Task {
            defer { isExporting = false }
            let snapshots = await store.exportSnapshots(for: range)
            guard !snapshots.isEmpty else {
                exportError = L10n.text("insights.export.noSamples")
                return
            }

            guard let destination = HistoryExportService.destination(
                suggestedName: "PowerLens-\(range.rawValue).\(format.fileExtension)"
            ) else {
                return
            }

            do {
                try await HistoryExportWriter.shared.write(
                    snapshots: snapshots,
                    format: format,
                    to: destination
                )
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func summaryGrid(_ summary: HistorySummary) -> some View {
        LazyVGrid(columns: columns, spacing: 14) {
            InsightsStatCard(
                title: L10n.text("insights.summary.avgLoad"),
                value: summary.avgSystemLoadW.map(Formatters.power) ?? L10n.text("common.none"),
                systemImage: "waveform.path.ecg"
            )
            InsightsStatCard(
                title: L10n.text("insights.summary.peakLoad"),
                value: summary.maxSystemLoadW.map(Formatters.power) ?? L10n.text("common.none"),
                systemImage: "bolt.horizontal"
            )
            InsightsStatCard(
                title: L10n.text("insights.summary.avgInput"),
                value: summary.avgAdapterInputPowerW.map(Formatters.power) ?? L10n.text("common.none"),
                systemImage: "powerplug.fill"
            )
            InsightsStatCard(
                title: L10n.text("insights.summary.avgTemp"),
                value: summary.avgTemperatureC.map(Formatters.temperature) ?? L10n.text("common.none"),
                systemImage: "thermometer.medium"
            )
            InsightsStatCard(
                title: L10n.text("insights.summary.batteryRange"),
                value: batteryRangeText(summary),
                systemImage: "battery.100"
            )
            InsightsStatCard(
                title: L10n.text("insights.summary.timeOnBattery"),
                value: durationText(summary.timeOnBattery),
                systemImage: "battery.50"
            )
            InsightsStatCard(
                title: L10n.text("insights.summary.timeOnExternal"),
                value: durationText(summary.timeOnExternal),
                systemImage: "powerplug"
            )
            InsightsStatCard(
                title: L10n.text("insights.summary.chargeSessions"),
                value: String(summary.chargeSessions),
                systemImage: "bolt.badge.clock"
            )
        }
    }

    private func batteryRangeText(_ summary: HistorySummary) -> String {
        guard let minLevel = summary.minBatteryLevel,
              let maxLevel = summary.maxBatteryLevel else {
            return L10n.text("common.none")
        }

        return L10n.tr("insights.summary.rangeValue", Formatters.percent(minLevel), Formatters.percent(maxLevel))
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else {
            return L10n.text("common.none")
        }

        return Formatters.minutes(Int(seconds / 60))
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(L10n.text("insights.loading"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
        .cardSurface()
    }

    private var emptyState: some View {
        Text(L10n.text("insights.empty"))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            .padding(Spacing.xLarge)
            .cardSurface()
    }
}

// MARK: - Summary card

private struct InsightsStatCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(Spacing.large)
        .cardSurface(cornerRadius: CornerRadius.large)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

// MARK: - Chart card shell

private struct InsightsChartCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            content()
                .frame(height: 220)
        }
        .padding(Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: CornerRadius.xLarge)
    }
}

// MARK: - Battery level chart

private struct BatteryLevelChartCard: View {
    private let levelPoints: [AggregatedTelemetryPoint]
    @State private var selectedDate: Date?

    private let timeLabel = L10n.text("ui.history.axis.time")
    private let batteryLabel = L10n.text("ui.history.axis.battery")

    init(points: [AggregatedTelemetryPoint]) {
        self.levelPoints = points.filter { $0.avgBatteryLevel != nil }
    }

    private var selectedPoint: AggregatedTelemetryPoint? {
        guard let selectedDate else { return nil }
        return InsightsCharts.nearest(to: selectedDate, in: levelPoints, by: \.bucketStart)
    }

    var body: some View {
        InsightsChartCard(
            title: L10n.text("insights.chart.battery.title"),
            subtitle: L10n.text("insights.chart.battery.subtitle")
        ) {
            Chart {
                ForEach(levelPoints) { point in
                    if let level = point.avgBatteryLevel {
                        LineMark(
                            x: .value(timeLabel, point.bucketStart),
                            y: .value(batteryLabel, level)
                        )
                        .foregroundStyle(.blue)
                        .interpolationMethod(.monotone)

                        AreaMark(
                            x: .value(timeLabel, point.bucketStart),
                            y: .value(batteryLabel, level)
                        )
                        .foregroundStyle(.blue.opacity(0.12))
                        .interpolationMethod(.monotone)
                    }
                }

                if let selectedPoint, let level = selectedPoint.avgBatteryLevel {
                    InsightsCharts.selectionRule(
                        timeLabel: timeLabel,
                        date: selectedPoint.bucketStart,
                        rows: [(batteryLabel, Formatters.percent(level))]
                    )
                }
            }
            .chartYScale(domain: 0 ... 100)
            .modifier(ChartXSelectionModifier(selection: $selectedDate))
            .accessibilityLabel(L10n.text("insights.chart.battery.title"))
        }
    }
}

// MARK: - Power flow chart

private struct PowerFlowChartCard: View {
    private let points: [AggregatedTelemetryPoint]
    @State private var selectedDate: Date?

    private let timeLabel = L10n.text("ui.history.axis.time")
    private let inputName = L10n.text("insights.series.input")
    private let loadName = L10n.text("insights.series.load")
    private let batteryName = L10n.text("insights.series.battery")

    init(points: [AggregatedTelemetryPoint]) {
        self.points = points
    }

    private var selectedPoint: AggregatedTelemetryPoint? {
        guard let selectedDate else { return nil }
        return InsightsCharts.nearest(to: selectedDate, in: points, by: \.bucketStart)
    }

    var body: some View {
        InsightsChartCard(
            title: L10n.text("insights.chart.power.title"),
            subtitle: L10n.text("insights.chart.power.subtitle")
        ) {
            Chart {
                ForEach(points) { point in
                    if let input = point.avgAdapterInputPowerW {
                        LineMark(
                            x: .value(timeLabel, point.bucketStart),
                            y: .value(loadName, input),
                            series: .value("Series", inputName)
                        )
                        .foregroundStyle(by: .value("Series", inputName))
                        .interpolationMethod(.monotone)
                    }

                    if let load = point.avgSystemLoadW {
                        LineMark(
                            x: .value(timeLabel, point.bucketStart),
                            y: .value(loadName, load),
                            series: .value("Series", loadName)
                        )
                        .foregroundStyle(by: .value("Series", loadName))
                        .interpolationMethod(.monotone)
                    }

                    if let battery = point.avgBatteryPowerW {
                        LineMark(
                            x: .value(timeLabel, point.bucketStart),
                            y: .value(loadName, battery),
                            series: .value("Series", batteryName)
                        )
                        .foregroundStyle(by: .value("Series", batteryName))
                        .interpolationMethod(.monotone)
                    }
                }

                if let selectedPoint {
                    InsightsCharts.selectionRule(
                        timeLabel: timeLabel,
                        date: selectedPoint.bucketStart,
                        rows: powerCalloutRows(selectedPoint)
                    )
                }
            }
            .chartForegroundStyleScale([
                inputName: Color.green,
                loadName: Color.orange,
                batteryName: Color.purple,
            ])
            .modifier(ChartXSelectionModifier(selection: $selectedDate))
            .accessibilityLabel(L10n.text("insights.chart.power.title"))
        }
    }

    private func powerCalloutRows(_ point: AggregatedTelemetryPoint) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let input = point.avgAdapterInputPowerW {
            rows.append((inputName, Formatters.power(input)))
        }
        if let load = point.avgSystemLoadW {
            rows.append((loadName, Formatters.power(load)))
        }
        if let battery = point.avgBatteryPowerW {
            rows.append((batteryName, Formatters.power(battery)))
        }
        return rows
    }
}

// MARK: - Battery health + cycles

private struct BatteryHealthSection: View {
    let trend: [BatteryHealthPoint]

    private var healthPoints: [BatteryHealthPoint] {
        trend.filter { $0.healthPercent != nil }
    }

    private var cyclePoints: [BatteryHealthPoint] {
        trend.filter { $0.cycleCount != nil }
    }

    var body: some View {
        if healthPoints.count >= 2 || cyclePoints.count >= 2 {
            VStack(alignment: .leading, spacing: 16) {
                if healthPoints.count >= 2 {
                    BatteryHealthChartCard(points: healthPoints)
                }

                if cyclePoints.count >= 2 {
                    ChargeCyclesChartCard(points: cyclePoints)
                }
            }
        } else {
            Text(L10n.text("insights.health.empty"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.large)
                .cardSurface()
        }
    }
}

private struct BatteryHealthChartCard: View {
    private let points: [BatteryHealthPoint]
    @State private var selectedDate: Date?

    private let timeLabel = L10n.text("ui.history.axis.time")
    private let capacityLabel = L10n.text("insights.series.capacity")

    init(points: [BatteryHealthPoint]) {
        self.points = points
    }

    private var selectedPoint: BatteryHealthPoint? {
        guard let selectedDate else { return nil }
        return InsightsCharts.nearest(to: selectedDate, in: points, by: \.date)
    }

    var body: some View {
        InsightsChartCard(
            title: L10n.text("insights.chart.health.title"),
            subtitle: L10n.text("insights.chart.health.subtitle")
        ) {
            Chart {
                ForEach(points) { point in
                    if let health = point.healthPercent {
                        LineMark(x: .value(timeLabel, point.date), y: .value(capacityLabel, health))
                            .foregroundStyle(.green)
                        PointMark(x: .value(timeLabel, point.date), y: .value(capacityLabel, health))
                            .foregroundStyle(.green)
                    }
                }

                if let selectedPoint, let health = selectedPoint.healthPercent {
                    InsightsCharts.selectionRule(
                        timeLabel: timeLabel,
                        date: selectedPoint.date,
                        rows: [(capacityLabel, Formatters.percent(health))]
                    )
                }
            }
            .modifier(ChartXSelectionModifier(selection: $selectedDate))
            .accessibilityLabel(L10n.text("insights.chart.health.title"))
        }
    }
}

private struct ChargeCyclesChartCard: View {
    private let points: [BatteryHealthPoint]
    @State private var selectedDate: Date?

    private let timeLabel = L10n.text("ui.history.axis.time")
    private let cyclesLabel = L10n.text("insights.series.cycles")

    init(points: [BatteryHealthPoint]) {
        self.points = points
    }

    private var selectedPoint: BatteryHealthPoint? {
        guard let selectedDate else { return nil }
        return InsightsCharts.nearest(to: selectedDate, in: points, by: \.date)
    }

    var body: some View {
        InsightsChartCard(
            title: L10n.text("insights.chart.cycles.title"),
            subtitle: L10n.text("insights.chart.cycles.subtitle")
        ) {
            Chart {
                ForEach(points) { point in
                    if let cycles = point.cycleCount {
                        LineMark(x: .value(timeLabel, point.date), y: .value(cyclesLabel, cycles))
                            .foregroundStyle(.teal)
                        PointMark(x: .value(timeLabel, point.date), y: .value(cyclesLabel, cycles))
                            .foregroundStyle(.teal)
                    }
                }

                if let selectedPoint, let cycles = selectedPoint.cycleCount {
                    InsightsCharts.selectionRule(
                        timeLabel: timeLabel,
                        date: selectedPoint.date,
                        rows: [(cyclesLabel, String(cycles))]
                    )
                }
            }
            .modifier(ChartXSelectionModifier(selection: $selectedDate))
            .accessibilityLabel(L10n.text("insights.chart.cycles.title"))
        }
    }
}

// MARK: - Shared chart helpers

enum InsightsCharts {
    static func nearest<Element>(
        to date: Date,
        in points: [Element],
        by dateKeyPath: KeyPath<Element, Date>
    ) -> Element? {
        points.min {
            abs($0[keyPath: dateKeyPath].timeIntervalSince(date)) < abs($1[keyPath: dateKeyPath].timeIntervalSince(date))
        }
    }

    /// A selection rule line with a value callout. When available, overflow
    /// resolution slides the callout inward at the chart edges instead of
    /// resizing the plot area and making the graph appear to shift.
    @ChartContentBuilder
    static func selectionRule(timeLabel: String, date: Date, rows: [(String, String)]) -> some ChartContent {
        if #available(macOS 14.0, *) {
            RuleMark(x: .value(timeLabel, date))
                .foregroundStyle(.secondary.opacity(0.4))
                .annotation(
                    position: .top,
                    alignment: .center,
                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                ) {
                    InsightsCallout(date: date, rows: rows)
                }
        } else {
            RuleMark(x: .value(timeLabel, date))
                .foregroundStyle(.secondary.opacity(0.4))
                .annotation(position: .top, alignment: .center) {
                    InsightsCallout(date: date, rows: rows)
                }
        }
    }
}

private struct InsightsCallout: View {
    let date: Date
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(date, format: .dateTime.month().day().hour().minute())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    Text(row.0)
                        .foregroundStyle(.secondary)
                    Text(row.1)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .font(.caption2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.quaternary.opacity(0.5), lineWidth: 0.8)
        }
    }
}

/// Applies interactive X-axis selection when the chart API is available.
private struct ChartXSelectionModifier: ViewModifier {
    @Binding var selection: Date?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.chartXSelection(value: $selection)
        } else {
            content
        }
    }
}

/// Presents the save panel on the main actor; the writer owns file I/O.
@MainActor
enum HistoryExportService {
    static func destination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.url
    }
}
