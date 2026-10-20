import Combine
import Foundation

struct InsightsRequest: Equatable {
    let range: HistoryRange
    let historyRevision: Int
}

/// Owns the result displayed by one Insights view. A database read can finish
/// after its task is cancelled, so publication also belongs to this lifecycle.
@MainActor
final class InsightsViewModel: ObservableObject {
    @Published private(set) var data: InsightsData?
    private var requestGeneration = 0

    func load(
        request: InsightsRequest,
        using loader: @MainActor (HistoryRange) async -> InsightsData
    ) async {
        guard !Task.isCancelled else {
            return
        }

        requestGeneration += 1
        let generation = requestGeneration
        if data?.range != request.range {
            data = nil
        }

        let result = await loader(request.range)
        guard !Task.isCancelled, generation == requestGeneration else {
            return
        }

        data = result
    }
}
