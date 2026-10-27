import Combine
import Foundation

/// Window-scoped query/export state outlives temporarily unmounted content.
@MainActor
final class DashboardSession: ObservableObject {
    let recentHistory = RecentPowerHistoryModel()
    let insights = InsightsViewModel()
    let exportState = HistoryExportState()
}

@MainActor
final class HistoryExportState: ObservableObject {
    @Published private(set) var isExporting = false
    @Published var error: String?

    func export(_ format: HistoryExportFormat, range: HistoryRange,
                loadSnapshots: @escaping @MainActor (HistoryRange) async throws -> [TelemetrySnapshot]) {
        guard !isExporting else {
            return
        }
        isExporting = true
        Task {
            defer { isExporting = false }
            let snapshots: [TelemetrySnapshot]
            do {
                snapshots = try await loadSnapshots(range)
            } catch {
                self.error = L10n.text("insights.export.loadFailed")
                return
            }
            guard !snapshots.isEmpty else {
                error = L10n.text("insights.export.noSamples")
                return
            }

            guard let destination = HistoryExportService.destination(
                suggestedName: "PowerLens-\(range.rawValue).\(format.fileExtension)"
            ) else {
                return
            }

            do {
                try await HistoryExportWriter.shared.write(
                    snapshots: snapshots,
                    format: format,
                    to: destination
                )
            } catch let failure {
                error = failure.localizedDescription
            }
        }
    }
}
