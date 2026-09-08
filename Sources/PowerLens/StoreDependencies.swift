import Foundation

protocol TelemetryReading: Sendable {
    func readSnapshot(preference: TelemetryEnginePreference) async throws -> TelemetryReadResult
}

protocol HistoryStoring: Sendable {
    func loadRecent(since cutoffDate: Date) async throws -> [TelemetrySnapshot]
    func append(_ snapshot: TelemetrySnapshot) async throws
    func purge(olderThan cutoffDate: Date, rollupBucketSeconds: Int?) async throws
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
