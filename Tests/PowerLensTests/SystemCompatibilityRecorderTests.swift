import Foundation
import Testing
@testable import PowerLens

struct SystemCompatibilityRecorderTests {
    @Test
    func equalObservationsAreDeduplicatedAndRefreshedHourly() async throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(
            at: fileURL.deletingLastPathComponent()
        ) }
        let recorder = SystemCompatibilityRecorder(
            fileURL: fileURL,
            observationWriteInterval: 3600,
            transitionLimit: 50
        )
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let diagnostic = SystemCompatibilityDiagnostic.compatiblePowerUI

        await recorder.record(diagnostic, observedAt: start)
        await recorder.record(
            diagnostic,
            observedAt: start.addingTimeInterval(30)
        )

        var document = await recorder.currentDocumentForTesting()
        #expect(document.currentStates.count == 1)
        #expect(document.currentStates[0].occurrenceCount == 2)
        #expect(document.recentTransitions.count == 1)

        await recorder.record(
            diagnostic,
            observedAt: start.addingTimeInterval(3600)
        )

        document = try decodeDocument(at: fileURL)
        #expect(document.currentStates[0].occurrenceCount == 3)
        #expect(
            document.currentStates[0].lastObservedAt
                == start.addingTimeInterval(3600)
        )
        #expect(document.recentTransitions.count == 1)
    }

    @Test
    func failedTransitionWriteRetriesOnTheNextEqualObservation() async throws {
        let fileManager = FileManager.default
        let fileURL = temporaryFileURL()
        defer { try? fileManager.removeItem(
            at: fileURL.deletingLastPathComponent()
        ) }
        let recorder = SystemCompatibilityRecorder(
            fileURL: fileURL,
            observationWriteInterval: 3600,
            transitionLimit: 50
        )
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let transitioned = diagnostic(
            .contractMismatch,
            .frameworkLoadFailed
        )

        await recorder.record(.compatiblePowerUI, observedAt: start)

        // Replacing the destination file with a directory forces the atomic
        // write to fail after an earlier state has already been persisted.
        try fileManager.removeItem(at: fileURL)
        try fileManager.createDirectory(
            at: fileURL,
            withIntermediateDirectories: false
        )
        await recorder.record(
            transitioned,
            observedAt: start.addingTimeInterval(1)
        )

        var isDirectory: ObjCBool = false
        #expect(fileManager.fileExists(
            atPath: fileURL.path,
            isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)

        try fileManager.removeItem(at: fileURL)
        await recorder.record(
            transitioned,
            observedAt: start.addingTimeInterval(2)
        )

        let document = try decodeDocument(at: fileURL)
        #expect(document.currentStates.first?.diagnostic == transitioned)
        #expect(document.currentStates.first?.occurrenceCount == 2)
        #expect(document.recentTransitions.count == 2)
        #expect(
            document.recentTransitions.last?.previousClassification
                == .compatible
        )
    }

    @Test
    func semanticTransitionsAreBoundedAndRecoveryIsRecorded() async {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(
            at: fileURL.deletingLastPathComponent()
        ) }
        let recorder = SystemCompatibilityRecorder(
            fileURL: fileURL,
            observationWriteInterval: 3600,
            transitionLimit: 3
        )
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let diagnostics = [
            diagnostic(.contractMismatch, .frameworkLoadFailed),
            diagnostic(.environmentUnavailable, .initializationFailed),
            diagnostic(.transientFailure, .queryFailed),
            .compatiblePowerUI,
        ]

        for (offset, value) in diagnostics.enumerated() {
            await recorder.record(
                value,
                observedAt: start.addingTimeInterval(Double(offset))
            )
        }

        let document = await recorder.currentDocumentForTesting()
        #expect(document.recentTransitions.count == 3)
        #expect(
            document.recentTransitions.last?.diagnostic
                == .compatiblePowerUI
        )
        #expect(
            document.recentTransitions.last?.previousClassification
                == .transientFailure
        )
        #expect(
            document.currentStates.first?.diagnostic
                == .compatiblePowerUI
        )
    }

    @Test
    func corruptFileIsReplacedWithAValidDocument() async throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(
            at: fileURL.deletingLastPathComponent()
        ) }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: fileURL, options: .atomic)
        let recorder = SystemCompatibilityRecorder(
            fileURL: fileURL,
            observationWriteInterval: 3600,
            transitionLimit: 50
        )

        await recorder.record(
            .compatiblePowerUI,
            observedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let document = try decodeDocument(at: fileURL)
        #expect(
            document.schemaVersion
                == SystemCompatibilityRecordDocument.currentSchemaVersion
        )
        #expect(document.currentStates.count == 1)
        #expect(document.recentTransitions.count == 1)
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: fileURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent) == ["system-compatibility.json"]
        )
    }

    @Test
    func unsupportedSchemaIsReplacedSafely() async throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(
            at: fileURL.deletingLastPathComponent()
        ) }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let unsupported = SystemCompatibilityRecordDocument(
            schemaVersion: 999,
            currentStates: [],
            recentTransitions: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(unsupported).write(to: fileURL, options: .atomic)
        let recorder = SystemCompatibilityRecorder(fileURL: fileURL)

        await recorder.record(
            .compatiblePowerUI,
            observedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let document = try decodeDocument(at: fileURL)
        #expect(
            document.schemaVersion
                == SystemCompatibilityRecordDocument.currentSchemaVersion
        )
        #expect(document.currentStates.first?.diagnostic == .compatiblePowerUI)
    }

    private func diagnostic(
        _ classification: SystemCompatibilityClassification,
        _ reason: SystemCompatibilityReasonCode
    ) -> SystemCompatibilityDiagnostic {
        SystemCompatibilityDiagnostic(
            subsystem: .powerUI,
            classification: classification,
            reason: reason,
            component: "PowerUI"
        )
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PowerLens-SystemCompatibilityTests-\(UUID().uuidString)",
                isDirectory: true
            )
            .appendingPathComponent("system-compatibility.json")
    }

    private func decodeDocument(
        at fileURL: URL
    ) throws -> SystemCompatibilityRecordDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            SystemCompatibilityRecordDocument.self,
            from: Data(contentsOf: fileURL)
        )
    }
}
