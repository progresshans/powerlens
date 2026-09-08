import Foundation
import Testing
@testable import PowerLens

struct HistoryExportWriterTests {
    @Test
    func anExportWritesTheSelectedFormat() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("history.json")
        let snapshots = [makeTelemetrySnapshot(systemLoadW: 12.5)]

        try await HistoryExportWriter().write(
            snapshots: snapshots,
            format: .json,
            to: destination
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode([TelemetrySnapshot].self, from: Data(contentsOf: destination))
        #expect(saved.count == 1)
        #expect(saved.first?.systemLoadW == 12.5)
    }

    @Test
    func aWriteFailureIsReturnedToTheCaller() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var reportedFailure = false

        do {
            try await HistoryExportWriter().write(
                snapshots: [makeTelemetrySnapshot()],
                format: .csv,
                to: directory
            )
        } catch {
            reportedFailure = true
        }

        #expect(reportedFailure)
    }

    @Test
    func aSerializationFailurePreservesAnExistingDestination() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("history.json")
        let original = Data("existing export".utf8)
        try original.write(to: destination)
        var reportedFailure = false

        do {
            try await HistoryExportWriter().write(
                snapshots: [makeTelemetrySnapshot(systemLoadW: .nan)],
                format: .json,
                to: destination
            )
        } catch {
            reportedFailure = true
        }

        #expect(reportedFailure)
        #expect(try Data(contentsOf: destination) == original)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PowerLensExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
