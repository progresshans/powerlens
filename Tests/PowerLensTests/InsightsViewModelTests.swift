import Foundation
import Testing
@testable import PowerLens

@MainActor
struct InsightsViewModelTests {
    @Test
    func aSupersededLoadCannotReplaceTheCurrentRange() async {
        let model = InsightsViewModel()
        let loader = SuspendedInsightsLoader()
        var starts = loader.starts.makeAsyncIterator()

        let oldLoad = Task {
            await model.load(
                request: InsightsRequest(range: .all, historyRevision: 1),
                using: loader.load
            )
        }
        _ = await starts.next()

        let currentLoad = Task {
            await model.load(
                request: InsightsRequest(range: .last24Hours, historyRevision: 1),
                using: loader.load
            )
        }
        _ = await starts.next()

        let current = InsightsData.empty(range: .last24Hours)
        loader.complete(1, with: current)
        await currentLoad.value
        loader.complete(0, with: .empty(range: .all))
        await oldLoad.value

        #expect(model.data == current)
    }

    @Test
    func aCancelledLoadDoesNotPublishAfterTheViewLeaves() async {
        let model = InsightsViewModel()
        let original = InsightsData.empty(range: .last24Hours)
        await model.load(
            request: InsightsRequest(range: .last24Hours, historyRevision: 1),
            using: { _ in original }
        )

        let loader = SuspendedInsightsLoader()
        var starts = loader.starts.makeAsyncIterator()
        let cancelledLoad = Task {
            await model.load(
                request: InsightsRequest(range: .last24Hours, historyRevision: 2),
                using: loader.load
            )
        }
        _ = await starts.next()
        cancelledLoad.cancel()
        loader.complete(0, with: .empty(range: .last24Hours, now: .distantFuture))
        await cancelledLoad.value

        #expect(model.data == original)
    }

    @Test
    func aNewHistoryRevisionReloadsTheSameRange() async {
        let model = InsightsViewModel()
        let original = InsightsData.empty(range: .last24Hours)
        let updated = InsightsData.empty(range: .last24Hours, now: .distantFuture)
        await model.load(
            request: InsightsRequest(range: .last24Hours, historyRevision: 1),
            using: { _ in original }
        )
        await model.load(
            request: InsightsRequest(range: .last24Hours, historyRevision: 2),
            using: { _ in updated }
        )

        #expect(model.data == updated)
    }

    @Test
    func changingRangeHidesDataFromThePreviousRangeWhileLoading() async {
        let model = InsightsViewModel()
        await model.load(
            request: InsightsRequest(range: .all, historyRevision: 1),
            using: { .empty(range: $0) }
        )

        let loader = SuspendedInsightsLoader()
        var starts = loader.starts.makeAsyncIterator()
        let newLoad = Task {
            await model.load(
                request: InsightsRequest(range: .last7Days, historyRevision: 1),
                using: loader.load
            )
        }
        _ = await starts.next()
        #expect(model.data == nil)

        loader.complete(0, with: .empty(range: .last7Days))
        await newLoad.value
        #expect(model.data?.range == .last7Days)
    }
}

@MainActor
private final class SuspendedInsightsLoader {
    let starts: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation
    private var requests: [CheckedContinuation<InsightsData, Never>] = []

    init() {
        (starts, started) = AsyncStream.makeStream(of: Void.self)
    }

    func load(_ range: HistoryRange) async -> InsightsData {
        await withCheckedContinuation { continuation in
            requests.append(continuation)
            started.yield(())
        }
    }

    func complete(_ index: Int, with data: InsightsData) {
        requests[index].resume(returning: data)
    }
}
