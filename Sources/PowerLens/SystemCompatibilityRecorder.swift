import Foundation
import OSLog

protocol SystemCompatibilityRecording: Sendable {
    func record(
        _ diagnostic: SystemCompatibilityDiagnostic,
        observedAt: Date
    ) async
}

struct SystemCompatibilityCurrentState: Codable, Equatable, Sendable {
    let subsystem: SystemCompatibilitySubsystem
    var diagnostic: SystemCompatibilityDiagnostic
    var firstObservedAt: Date
    var lastObservedAt: Date
    var occurrenceCount: Int
}

struct SystemCompatibilityTransition: Codable, Equatable, Sendable {
    let observedAt: Date
    let previousClassification: SystemCompatibilityClassification?
    let diagnostic: SystemCompatibilityDiagnostic
}

struct SystemCompatibilityRecordDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var currentStates: [SystemCompatibilityCurrentState]
    var recentTransitions: [SystemCompatibilityTransition]

    static let empty = SystemCompatibilityRecordDocument(
        schemaVersion: currentSchemaVersion,
        currentStates: [],
        recentTransitions: []
    )
}

actor SystemCompatibilityRecorder: SystemCompatibilityRecording {
    private enum RecordError: Error {
        case unsupportedSchema(Int)
        case duplicateCurrentState(SystemCompatibilitySubsystem)
    }

    static let shared = SystemCompatibilityRecorder()

    private static let logger = Logger(
        subsystem: "com.progresshans.powerlens",
        category: "SystemCompatibility"
    )

    private let fileURL: URL
    private let fileManager: FileManager
    private let observationWriteInterval: TimeInterval
    private let transitionLimit: Int
    private var document: SystemCompatibilityRecordDocument?
    private var persistedObservationDates: [SystemCompatibilitySubsystem: Date]
        = [:]

    init(
        fileURL: URL = SystemCompatibilityRecorder.defaultFileURL,
        fileManager: FileManager = .default,
        observationWriteInterval: TimeInterval = 3600,
        transitionLimit: Int = 50
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.observationWriteInterval = max(0, observationWriteInterval)
        self.transitionLimit = max(1, transitionLimit)
    }

    func record(
        _ diagnostic: SystemCompatibilityDiagnostic,
        observedAt: Date
    ) async {
        loadIfNeeded()
        guard var document else {
            return
        }

        let stateIndex = document.currentStates.firstIndex {
            $0.subsystem == diagnostic.subsystem
        }
        var shouldPersist = false

        if let stateIndex {
            let previous = document.currentStates[stateIndex]
            if previous.diagnostic == diagnostic {
                document.currentStates[stateIndex].lastObservedAt = observedAt
                document.currentStates[stateIndex].occurrenceCount += 1

                if let lastPersisted = persistedObservationDates[
                    diagnostic.subsystem
                ] {
                    shouldPersist = observedAt.timeIntervalSince(lastPersisted)
                        >= observationWriteInterval
                } else {
                    // A prior write may have failed. Retry on the next sample
                    // instead of suppressing writes for a full hour.
                    shouldPersist = true
                }
            } else {
                document.currentStates[stateIndex] =
                    SystemCompatibilityCurrentState(
                        subsystem: diagnostic.subsystem,
                        diagnostic: diagnostic,
                        firstObservedAt: observedAt,
                        lastObservedAt: observedAt,
                        occurrenceCount: 1
                    )
                appendTransition(
                    to: &document,
                    diagnostic: diagnostic,
                    previousClassification: previous.diagnostic.classification,
                    observedAt: observedAt
                )
                logTransition(
                    diagnostic,
                    previousClassification: previous.diagnostic.classification
                )
                shouldPersist = true
            }
        } else {
            document.currentStates.append(
                SystemCompatibilityCurrentState(
                    subsystem: diagnostic.subsystem,
                    diagnostic: diagnostic,
                    firstObservedAt: observedAt,
                    lastObservedAt: observedAt,
                    occurrenceCount: 1
                )
            )
            document.currentStates.sort {
                $0.subsystem.rawValue < $1.subsystem.rawValue
            }
            appendTransition(
                to: &document,
                diagnostic: diagnostic,
                previousClassification: nil,
                observedAt: observedAt
            )
            logTransition(diagnostic, previousClassification: nil)
            shouldPersist = true
        }

        self.document = document
        guard shouldPersist else {
            return
        }

        do {
            try persist(document)
            persistedObservationDates[diagnostic.subsystem] = observedAt
        } catch {
            // The in-memory document already contains the latest observation.
            // Forget the older on-disk timestamp so the next sample retries it
            // immediately, including after a failed semantic transition.
            persistedObservationDates[diagnostic.subsystem] = nil
            Self.logger.error(
                "Compatibility record write failed; error: \(String(describing: error), privacy: .private)"
            )
        }
    }

    func currentDocumentForTesting() -> SystemCompatibilityRecordDocument {
        loadIfNeeded()
        return document ?? .empty
    }

    private func loadIfNeeded() {
        guard document == nil else {
            return
        }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            document = .empty
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(
                SystemCompatibilityRecordDocument.self,
                from: data
            )
            guard decoded.schemaVersion
                    == SystemCompatibilityRecordDocument.currentSchemaVersion
            else {
                throw RecordError.unsupportedSchema(decoded.schemaVersion)
            }

            let observationDates = try validatedObservationDates(
                from: decoded.currentStates
            )
            document = decoded
            persistedObservationDates = observationDates
        } catch {
            document = .empty
            persistedObservationDates = [:]
            Self.logger.error(
                "Compatibility record could not be read and will be replaced; error: \(String(describing: error), privacy: .private)"
            )
        }
    }

    private func validatedObservationDates(
        from currentStates: [SystemCompatibilityCurrentState]
    ) throws -> [SystemCompatibilitySubsystem: Date] {
        var dates: [SystemCompatibilitySubsystem: Date] = [:]
        for state in currentStates {
            guard dates[state.subsystem] == nil else {
                throw RecordError.duplicateCurrentState(state.subsystem)
            }
            dates[state.subsystem] = state.lastObservedAt
        }
        return dates
    }

    private func appendTransition(
        to document: inout SystemCompatibilityRecordDocument,
        diagnostic: SystemCompatibilityDiagnostic,
        previousClassification: SystemCompatibilityClassification?,
        observedAt: Date
    ) {
        document.recentTransitions.append(
            SystemCompatibilityTransition(
                observedAt: observedAt,
                previousClassification: previousClassification,
                diagnostic: diagnostic
            )
        )
        if document.recentTransitions.count > transitionLimit {
            document.recentTransitions.removeFirst(
                document.recentTransitions.count - transitionLimit
            )
        }
    }

    private func persist(
        _ document: SystemCompatibilityRecordDocument
    ) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: .atomic)
    }

    private func logTransition(
        _ diagnostic: SystemCompatibilityDiagnostic,
        previousClassification: SystemCompatibilityClassification?
    ) {
        let previous = previousClassification?.rawValue ?? "none"
        let component = diagnostic.component ?? "none"
        Self.logger.info(
            "Compatibility transition; subsystem=\(diagnostic.subsystem.rawValue, privacy: .public); previous=\(previous, privacy: .public); current=\(diagnostic.classification.rawValue, privacy: .public); reason=\(diagnostic.reason.rawValue, privacy: .public); component=\(component, privacy: .public)"
        )
    }

    private static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return applicationSupport
            .appendingPathComponent("PowerLens", isDirectory: true)
            .appendingPathComponent("system-compatibility.json")
    }
}
