import Foundation

/// Versioned, lossless numeric observations alongside the existing scaled
/// columns used by SQL aggregates. No policy, app, or hardware identifiers.
struct HistoricalMeasurements: Codable, Equatable, Sendable {
    let version: Int
    let capturedAt: Date
    let batteryLevel: Double?
    let batteryTemperatureC: Double?
    let batteryVoltageV: Double?
    let batteryCurrentA: Double?
    let batteryPowerW: Double?
    let adapterMaxPowerW: Double?
    let adapterInputPowerW: Double?
    let adapterVoltageV: Double?
    let adapterCurrentA: Double?
    let systemLoadW: Double?
    let powerMeasurementSetSource: PowerMeasurementSetSource?

    init(_ snapshot: TelemetrySnapshot) {
        version = 1
        capturedAt = snapshot.timestamp
        batteryLevel = snapshot.batteryLevel
        batteryTemperatureC = snapshot.batteryTemperatureC
        batteryVoltageV = snapshot.batteryVoltageV
        batteryCurrentA = snapshot.batteryCurrentA
        batteryPowerW = snapshot.batteryPowerW
        adapterMaxPowerW = snapshot.adapterMaxPowerW
        adapterInputPowerW = snapshot.adapterInputPowerW
        adapterVoltageV = snapshot.adapterVoltageV
        adapterCurrentA = snapshot.adapterCurrentA
        systemLoadW = snapshot.systemLoadW
        powerMeasurementSetSource = snapshot.powerMeasurementSetSource
    }

    func encoded() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    static func decode(_ text: String) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard value.version == 1 else {
            throw HistoryStoreError.invalidConfiguration("Unsupported historical measurement version: \(value.version)")
        }
        return value
    }
}

struct StoredTelemetrySample: Sendable {
    enum ID: Hashable, Sendable {
        case database(Int64)
        case snapshot(UUID)
    }

    let id: ID
    let snapshot: TelemetrySnapshot
}
