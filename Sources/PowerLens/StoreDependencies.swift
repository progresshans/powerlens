import Foundation

protocol TelemetryReading: Sendable {
    func readSnapshot(preference: TelemetryEnginePreference) async throws -> TelemetryReadResult
}

protocol HistoryStoring: Sendable {
    func loadRecent(since cutoffDate: Date) async -> [TelemetrySnapshot]
    func append(_ snapshot: TelemetrySnapshot) async
}
