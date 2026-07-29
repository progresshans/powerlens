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
