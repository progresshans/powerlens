import Foundation
import Testing
@testable import PowerLens

@MainActor
struct RecentPowerHistoryModelTests {
    private enum ReadFailure: Error { case unavailable }

    @Test
    func failureIsNotAnEmptySuccessfulHistoryAndCanRecover() async {
        let model = RecentPowerHistoryModel()
        await model.load { throw ReadFailure.unavailable }
        #expect(model.hasReadFailure)
        await model.load { [] }
        #expect(model.state == .loaded([]))
    }

    @Test
    func aFailedReloadKeepsThePreviousResultAndStillReportsTheFailure() async {
        let model = RecentPowerHistoryModel()
        let samples = [RecentPowerSample(snapshot: makeTelemetrySnapshot())]
        await model.load { samples }
        await model.load { throw ReadFailure.unavailable }
        #expect(model.hasReadFailure)
        #expect(model.samples == samples)
        await model.load { [] }
        #expect(!model.hasReadFailure)
        #expect(model.samples.isEmpty)
    }

    @Test
    func anOldQueryCannotReplaceANewerResult() async {
        let model = RecentPowerHistoryModel()
        let gate = HistoryQueryGate()
        var starts = gate.starts.makeAsyncIterator()
        let old = Task { await model.load(using: gate.load) }
        _ = await starts.next()
        let current = [RecentPowerSample(snapshot: makeTelemetrySnapshot())]
        await model.load { current }
        gate.finish([])
        await old.value
        #expect(model.samples == current)
    }

    @Test
    func leavingThePageInvalidatesAPendingQuery() async {
        let model = RecentPowerHistoryModel()
        let gate = HistoryQueryGate()
        var starts = gate.starts.makeAsyncIterator()
        let query = Task { await model.load(using: gate.load) }
        _ = await starts.next()
        query.cancel()
        gate.finish([RecentPowerSample(snapshot: makeTelemetrySnapshot())])
        await query.value
        #expect(model.state == .loading)
    }
}

@MainActor
private final class HistoryQueryGate {
    let starts: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var pending: CheckedContinuation<[RecentPowerSample], Never>?

    init() { (starts, continuation) = AsyncStream.makeStream(of: Void.self) }
    func load() async throws -> [RecentPowerSample] {
        await withCheckedContinuation {
            pending = $0
            continuation.yield(())
        }
    }
    func finish(_ result: [RecentPowerSample]) {
        pending?.resume(returning: result)
        pending = nil
    }
}
