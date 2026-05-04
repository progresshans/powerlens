import Foundation

enum TelemetryEnginePreference: String, CaseIterable, Identifiable, Sendable {
    case auto
    case compatible
    case livePrecision

    static let storageKey = "telemetryEnginePreference"

    var id: String { rawValue }

    static var current: TelemetryEnginePreference {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let preference = TelemetryEnginePreference(rawValue: raw) else {
            return .auto
        }
        return preference
    }

    var displayName: String {
        switch self {
        case .auto:
            L10n.text("telemetry.engine.auto")
        case .compatible:
            L10n.text("telemetry.engine.compatible")
        case .livePrecision:
            L10n.text("telemetry.engine.livePrecision")
        }
    }

    var detail: String {
        switch self {
        case .auto:
            L10n.text("telemetry.description.auto")
        case .compatible:
            L10n.text("telemetry.description.compatible")
        case .livePrecision:
            L10n.text("telemetry.description.livePrecision")
        }
    }
}

enum TelemetryEngineKind: String, Codable, Equatable, Sendable {
    case compatible
    case livePrecision

    var displayName: String {
        switch self {
        case .compatible:
            L10n.text("telemetry.engine.compatible")
        case .livePrecision:
            L10n.text("telemetry.engine.livePrecision")
        }
    }
}

struct TelemetryReadResult: Sendable {
    let snapshot: TelemetrySnapshot
    let activeEngine: TelemetryEngineKind
}

enum TelemetryReadError: Error {
    case unavailable
}

protocol TelemetrySnapshotReader {
    func readSnapshot() throws -> TelemetrySnapshot
}

struct TelemetryCoordinator {
    private let compatibleReader: any TelemetrySnapshotReader
    private let livePrecisionReader: any TelemetrySnapshotReader

    init(
        compatibleReader: any TelemetrySnapshotReader = CompatibleTelemetryReader(),
        livePrecisionReader: any TelemetrySnapshotReader = LivePrecisionTelemetryReader()
    ) {
        self.compatibleReader = compatibleReader
        self.livePrecisionReader = livePrecisionReader
    }

    func readSnapshot(preference: TelemetryEnginePreference) throws -> TelemetryReadResult {
        switch preference {
        case .auto:
            if let snapshot = try? livePrecisionReader.readSnapshot() {
                return TelemetryReadResult(snapshot: snapshot, activeEngine: .livePrecision)
            }
            return TelemetryReadResult(
                snapshot: try compatibleReader.readSnapshot(),
                activeEngine: .compatible
            )
        case .compatible:
            return TelemetryReadResult(
                snapshot: try compatibleReader.readSnapshot(),
                activeEngine: .compatible
            )
        case .livePrecision:
            if let snapshot = try? livePrecisionReader.readSnapshot() {
                return TelemetryReadResult(snapshot: snapshot, activeEngine: .livePrecision)
            }
            return TelemetryReadResult(
                snapshot: try compatibleReader.readSnapshot(),
                activeEngine: .compatible
            )
        }
    }
}
