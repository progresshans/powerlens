import Foundation

protocol TelemetryReading: Sendable {
    func readSnapshot(preference: TelemetryEnginePreference) async throws -> TelemetryReadResult
}

protocol EnergyModeReading: Sendable {
    func read(lowPowerFallback: Bool) async -> EnergyMode
}

protocol HistoryStoring: Sendable {
    func latestSampleTimestamp() async throws -> Date?
    func loadRecent(since cutoffDate: Date) async throws -> [TelemetrySnapshot]
    func loadRecentRecords(since cutoffDate: Date) async throws -> [StoredTelemetrySample]
    func append(_ snapshot: TelemetrySnapshot) async throws
    func purge(olderThan cutoffDate: Date, rollupBucketSeconds: Int?) async throws
    func removeExpiredBackups(now: Date, discardingAll: Bool) async throws
    func summary(for range: DateInterval) async throws -> HistorySummary
    func aggregatedSeries(
        for range: DateInterval,
        bucketSeconds: Int
    ) async throws -> [AggregatedTelemetryPoint]
    func rollupSeries(
        for range: DateInterval
    ) async throws -> [AggregatedTelemetryPoint]
    func batteryHealthTrend(
        since cutoffDate: Date
    ) async throws -> [BatteryHealthPoint]
    func loadInsights(for range: HistoryRange, now: Date) async throws -> InsightsData
}

extension HistoryStoring {
    func removeExpiredBackups(now: Date, discardingAll: Bool) async throws {}

    func loadRecentRecords(since cutoffDate: Date) async throws -> [StoredTelemetrySample] {
        try await loadRecent(since: cutoffDate).map {
            StoredTelemetrySample(id: .snapshot($0.id), snapshot: $0)
        }
    }

    func loadInsights(for range: HistoryRange, now: Date) async throws -> InsightsData {
        let interval = range.interval(now: now)
        try Task.checkCancellation()
        let rawSeries = try await aggregatedSeries(for: interval, bucketSeconds: range.bucketSeconds)
        try Task.checkCancellation()
        let rollups = try await rollupSeries(for: interval)
        try Task.checkCancellation()
        let summary = try await summary(for: interval)
        try Task.checkCancellation()
        let healthTrend = try await batteryHealthTrend(since: Date(timeIntervalSince1970: 0))
        try Task.checkCancellation()
        return InsightsData(
            range: range,
            interval: interval,
            series: (rollups + rawSeries).sorted { $0.bucketStart < $1.bucketStart },
            summary: summary,
            healthTrend: healthTrend
        )
    }
}

enum TelemetryHealth: Equatable, Sendable {
    case waiting
    case live
    case delayed(failedAttempts: Int)
    case unavailable(failedAttempts: Int)

    var failedAttempts: Int {
        switch self {
        case .waiting, .live:
            0
        case let .delayed(failedAttempts),
             let .unavailable(failedAttempts):
            failedAttempts
        }
    }

    var isUnavailable: Bool {
        if case .unavailable = self {
            return true
        }
        return false
    }
}

enum HistoryHealth: Equatable, Sendable {
    case checking
    case available
    case degraded
}

/// One point of the Dashboard's last-hour chart, read from saved history.
struct RecentPowerSample: Equatable, Sendable, Identifiable {
    static let window: TimeInterval = 3600

    let date: Date
    let inputW: Double?
    let systemW: Double?
    var id: StoredTelemetrySample.ID = .snapshot(UUID())
}

extension RecentPowerSample {
    /// Uses the same balanced values as the live readouts, so the chart agrees
    /// with the cards above it.
    init(snapshot: TelemetrySnapshot) {
        let readings = PowerFlowReadings(snapshot: snapshot)
        self.init(
            date: snapshot.timestamp,
            inputW: snapshot.externalConnected ? readings.inputPower?.watts : 0,
            systemW: readings.systemPower?.watts
        )
        id = .snapshot(snapshot.id)
    }

    init(record: StoredTelemetrySample) {
        self.init(snapshot: record.snapshot)
        id = record.id
    }
}
