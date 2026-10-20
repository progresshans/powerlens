import Foundation

/// Keeps serialization and file I/O off the main actor, and only replaces an
/// existing export after the complete payload is ready to write.
actor HistoryExportWriter {
    static let shared = HistoryExportWriter()

    func write(
        snapshots: [TelemetrySnapshot],
        format: HistoryExportFormat,
        to destination: URL
    ) throws {
        let payload = try HistoryExporter.data(for: snapshots, format: format)
        try payload.write(to: destination, options: .atomic)
    }
}
