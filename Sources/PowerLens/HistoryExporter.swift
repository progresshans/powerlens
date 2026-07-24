import Foundation

/// Export file formats for the local telemetry history.
enum HistoryExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv
    case json

    var id: String { rawValue }

    var fileExtension: String { rawValue }

    var title: String {
        switch self {
        case .csv:
            "CSV"
        case .json:
            "JSON"
        }
    }
}

/// Pure serialization of telemetry snapshots to CSV or JSON. No file or panel
/// I/O lives here so the formatting is unit testable.
enum HistoryExporter {
    static let csvColumns = [
        "timestamp_iso",
        "battery_level",
        "power_source",
        "is_charging",
        "is_charged",
        "external_connected",
        "battery_power_w",
        "adapter_input_power_w",
        "system_load_w",
        "battery_temperature_c",
        "battery_voltage_v",
        "battery_current_a",
        "cycle_count",
        "full_charge_capacity_mah",
        "thermal_state",
        "frontmost_app",
    ]

    static func csv(_ snapshots: [TelemetrySnapshot]) -> String {
        let formatter = ISO8601DateFormatter()
        let header = csvColumns.joined(separator: ",")

        let rows = snapshots.map { snapshot in
            [
                formatter.string(from: snapshot.timestamp),
                numberField(snapshot.batteryLevel),
                snapshot.powerSource.rawValue,
                snapshot.isCharging ? "1" : "0",
                snapshot.isCharged ? "1" : "0",
                snapshot.externalConnected ? "1" : "0",
                numberField(snapshot.batteryPowerW),
                numberField(snapshot.adapterInputPowerW),
                numberField(snapshot.systemLoadW),
                numberField(snapshot.batteryTemperatureC),
                numberField(snapshot.batteryVoltageV),
                numberField(snapshot.batteryCurrentA),
                snapshot.cycleCount.map(String.init) ?? "",
                snapshot.fullChargeCapacityMah.map(String.init) ?? "",
                escape(snapshot.thermalState),
                escape(snapshot.frontmostAppName ?? ""),
            ].joined(separator: ",")
        }

        return ([header] + rows).joined(separator: "\n")
    }

    static func jsonData(_ snapshots: [TelemetrySnapshot]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(
            snapshots.map { $0.withChargingPolicyStatus(nil) }
        )
    }

    static func data(for snapshots: [TelemetrySnapshot], format: HistoryExportFormat) throws -> Data {
        switch format {
        case .csv:
            Data(csv(snapshots).utf8)
        case .json:
            try jsonData(snapshots)
        }
    }

    private static func numberField(_ value: Double?) -> String {
        guard let value else {
            return ""
        }

        return String(format: "%.3f", value)
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }

        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
