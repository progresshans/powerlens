import Foundation

struct InsightsRequest: Equatable {
    let range: HistoryRange
    let historyRevision: Int
}

typealias InsightsViewModel = HistoryQueryModel<InsightsData>

extension HistoryQueryModel where Value == InsightsData {
    func load(request: InsightsRequest,
              using loader: @MainActor (HistoryRange) async throws -> InsightsData) async {
        await load(clearBeforeLoad: data?.range != request.range) {
            try await loader(request.range)
        }
    }
}
