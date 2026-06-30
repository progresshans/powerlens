import Foundation

protocol TelemetryReading: Sendable {
    func readSnapshot(preference: TelemetryEnginePreference) async throws -> TelemetryReadResult
}

protocol HistoryStoring: Sendable {
    func loadRecent(since cutoffDate: Date) async -> [TelemetrySnapshot]
    func append(_ snapshot: TelemetrySnapshot) async
    func purge(olderThan cutoffDate: Date, rollupBucketSeconds: Int?) async
    func summary(for range: DateInterval) async -> HistorySummary
    func aggregatedSeries(for range: DateInterval, bucketSeconds: Int) async -> [AggregatedTelemetryPoint]
    func rollupSeries(for range: DateInterval) async -> [AggregatedTelemetryPoint]
    func batteryHealthTrend(since cutoffDate: Date) async -> [BatteryHealthPoint]
}
