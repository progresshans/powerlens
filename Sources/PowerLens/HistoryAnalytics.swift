import Foundation

/// A user-selectable time window for the Insights views.
///
/// Each range also defines the aggregation bucket size used when querying the
/// history store, chosen to keep the number of plotted points reasonable
/// regardless of how long the range is.
enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case last24Hours
    case last7Days
    case last30Days
    case all

    static let storageKey = "insights.selectedRange"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .last24Hours:
            L10n.text("insights.range.24h")
        case .last7Days:
            L10n.text("insights.range.7d")
        case .last30Days:
            L10n.text("insights.range.30d")
        case .all:
            L10n.text("insights.range.all")
        }
    }

    /// Lookback window in seconds. `nil` means "all available history".
    var lookback: TimeInterval? {
        switch self {
        case .last24Hours:
            24 * 3_600
        case .last7Days:
            7 * 24 * 3_600
        case .last30Days:
            30 * 24 * 3_600
        case .all:
            nil
        }
    }

    /// Aggregation bucket size in seconds, sized to give each range meaningful
    /// detail while keeping plotted point counts bounded for smooth scrubbing
    /// (roughly 180-500 points across the range).
    var bucketSeconds: Int {
        switch self {
        case .last24Hours:
            5 * 60          // ~288 points
        case .last7Days:
            20 * 60         // ~504 points
        case .last30Days:
            2 * 60 * 60     // ~360 points
        case .all:
            12 * 60 * 60    // bounded across the retention window
        }
    }

    /// The concrete date interval for this range relative to `now`.
    func interval(now: Date = .now) -> DateInterval {
        guard let lookback else {
            return DateInterval(start: Date(timeIntervalSince1970: 0), end: now)
        }

        return DateInterval(start: now.addingTimeInterval(-lookback), end: now)
    }
}

/// A downsampled bucket of telemetry samples produced by the history store's
/// aggregation query. All optional fields are `nil` when no sample in the
/// bucket carried that value.
struct AggregatedTelemetryPoint: Identifiable, Equatable, Sendable {
    let bucketStart: Date
    let avgBatteryLevel: Double?
    let minBatteryLevel: Double?
    let maxBatteryLevel: Double?
    let avgAdapterInputPowerW: Double?
    let avgSystemLoadW: Double?
    let maxSystemLoadW: Double?
    let avgBatteryPowerW: Double?
    let avgTemperatureC: Double?
    let maxTemperatureC: Double?
    let sampleCount: Int

    var id: Date { bucketStart }
}

/// Aggregate statistics for a range, used by the Insights summary cards.
struct HistorySummary: Equatable, Sendable {
    let range: DateInterval
    let sampleCount: Int
    let avgSystemLoadW: Double?
    let maxSystemLoadW: Double?
    let avgAdapterInputPowerW: Double?
    let avgTemperatureC: Double?
    let maxTemperatureC: Double?
    let minBatteryLevel: Double?
    let maxBatteryLevel: Double?
    let timeOnBattery: TimeInterval
    let timeOnExternal: TimeInterval
    let chargeSessions: Int

    var isEmpty: Bool {
        sampleCount == 0
    }

    static func empty(range: DateInterval) -> HistorySummary {
        HistorySummary(
            range: range,
            sampleCount: 0,
            avgSystemLoadW: nil,
            maxSystemLoadW: nil,
            avgAdapterInputPowerW: nil,
            avgTemperatureC: nil,
            maxTemperatureC: nil,
            minBatteryLevel: nil,
            maxBatteryLevel: nil,
            timeOnBattery: 0,
            timeOnExternal: 0,
            chargeSessions: 0
        )
    }
}

/// One point on the long-term battery-health trend, derived from the
/// de-duplicated `battery_states` history (one entry per distinct slow state).
struct BatteryHealthPoint: Identifiable, Equatable, Sendable {
    let date: Date
    let fullChargeCapacityMah: Int?
    let designCapacityMah: Int?
    let nominalCapacityMah: Int?
    let cycleCount: Int?

    var id: Date { date }

    /// Full-charge capacity as a percentage of design capacity.
    var healthPercent: Double? {
        guard let fullChargeCapacityMah,
              let designCapacityMah,
              designCapacityMah > 0 else {
            return nil
        }

        return Double(fullChargeCapacityMah) / Double(designCapacityMah) * 100
    }
}

/// The full set of data the Insights view renders for a selected range.
struct InsightsData: Equatable, Sendable {
    let range: HistoryRange
    let interval: DateInterval
    let series: [AggregatedTelemetryPoint]
    let summary: HistorySummary
    let healthTrend: [BatteryHealthPoint]

    var hasSeries: Bool {
        series.contains { $0.sampleCount > 0 }
    }

    static func empty(range: HistoryRange, now: Date = .now) -> InsightsData {
        let interval = range.interval(now: now)
        return InsightsData(
            range: range,
            interval: interval,
            series: [],
            summary: .empty(range: interval),
            healthTrend: []
        )
    }
}
