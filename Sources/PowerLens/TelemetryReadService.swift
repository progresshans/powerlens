import Foundation

actor TelemetryReadService: TelemetryReading {
    private let coordinator = TelemetryCoordinator()

    func readSnapshot(preference: TelemetryEnginePreference) async throws -> TelemetryReadResult {
        try coordinator.readSnapshot(preference: preference)
    }
}
