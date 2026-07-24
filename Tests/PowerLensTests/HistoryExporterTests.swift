import Foundation
import Testing
@testable import PowerLens

struct HistoryExporterTests {
    @Test
    func csvHasHeaderAndOneRowPerSnapshot() {
        let snapshots = [
            makeTelemetrySnapshot(systemLoadW: 12.5),
            makeTelemetrySnapshot(systemLoadW: 20),
        ]

        let csv = HistoryExporter.csv(snapshots)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines.count == 3)
        #expect(String(lines[0]) == HistoryExporter.csvColumns.joined(separator: ","))
        #expect(String(lines[1]).contains("12.500"))
    }

    @Test
    func jsonRoundTripsSnapshots() throws {
        let snapshots = [
            makeTelemetrySnapshot(
                systemLoadW: 12.5,
                chargingPolicyStatus: .manualLimit(targetPercent: 87)
            )
        ]

        let data = try HistoryExporter.jsonData(snapshots)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([TelemetrySnapshot].self, from: data)

        #expect(decoded.count == 1)
        #expect(decoded.first?.systemLoadW == 12.5)
        #expect(decoded.first?.cycleCount == 75)
        #expect(decoded.first?.chargingPolicyStatus == nil)
    }

    @Test
    func dataForFormatMatchesSerializers() throws {
        let snapshots = [makeTelemetrySnapshot(systemLoadW: 9)]

        let csvData = try HistoryExporter.data(for: snapshots, format: .csv)
        #expect(String(data: csvData, encoding: .utf8) == HistoryExporter.csv(snapshots))

        let jsonData = try HistoryExporter.data(for: snapshots, format: .json)
        #expect(jsonData == (try HistoryExporter.jsonData(snapshots)))
    }
}
