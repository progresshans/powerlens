import Foundation
import Testing
@testable import PowerLens

struct ProcessEnergySamplerTests {
    @Test
    func samplerRunsOffACachedTenSecondInterval() async {
        let sequence = LockedProcessSampleSequence()
        let sampler = ProcessEnergySampler(
            minimumSampleInterval: 10,
            snapshotProvider: sequence.next
        )
        let start = Date(timeIntervalSince1970: 2_000_000_000)

        let initial = await sampler.sample(now: start)
        let cached = await sampler.sample(
            now: start.addingTimeInterval(5)
        )
        let measured = await sampler.sample(
            now: start.addingTimeInterval(10)
        )

        #expect(initial.isEmpty)
        #expect(cached.isEmpty)
        #expect(sequence.callCount == 2)
        #expect(measured.count == 1)
        #expect(measured.first?.name == "Test")
        #expect(abs((measured.first?.energyImpact ?? 0) - 10) < 0.001)
    }

    @Test(arguments: [1.0, 3_600.0])
    func resetDiscardsCachedResultsAndStartsAFreshBaseline(pause: TimeInterval) async {
        let sequence = LockedProcessSampleSequence()
        let sampler = ProcessEnergySampler(
            minimumSampleInterval: 10,
            snapshotProvider: sequence.next
        )
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        _ = await sampler.sample(now: start)
        let beforePause = await sampler.sample(now: start.addingTimeInterval(10))
        #expect(beforePause.count == 1)

        await sampler.reset()
        await sampler.reset()
        #expect(sequence.callCount == 2)

        let resumedAt = start.addingTimeInterval(10 + pause)
        let baseline = await sampler.sample(now: resumedAt)
        let cached = await sampler.sample(now: resumedAt.addingTimeInterval(5))
        #expect(baseline.isEmpty)
        #expect(cached.isEmpty)
        #expect(sequence.callCount == 3)

        let measured = await sampler.sample(now: resumedAt.addingTimeInterval(10))
        #expect(sequence.callCount == 4)
        #expect(measured.count == 1)
        #expect(abs((measured.first?.energyImpact ?? 0) - 10) < 0.001)
    }
}

private final class LockedProcessSampleSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func next() -> [ProcessEnergyProcessSample] {
        lock.lock()
        defer { lock.unlock() }

        calls += 1
        return [
            ProcessEnergyProcessSample(
                pid: 42,
                cpuNanoseconds: UInt64(calls) * 1_000_000_000,
                idleWakeups: 0,
                appPath: "/Applications/Test.app"
            )
        ]
    }
}
