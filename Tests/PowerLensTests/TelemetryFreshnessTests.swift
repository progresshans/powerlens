import Foundation
import Testing
@testable import PowerLens

struct TelemetryFreshnessTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test
    func successfulRecentSampleIsLive() {
        let freshness = TelemetryFreshness(
            refreshDate: now.addingTimeInterval(-5),
            health: .live,
            now: now
        )

        #expect(freshness.state == .live)
        #expect(freshness.isLive)
        #expect(!freshness.isCriticallyDelayed)
    }

    @Test
    func successfulButOldSampleIsReportedAsDelayed() {
        let freshness = TelemetryFreshness(
            refreshDate: now.addingTimeInterval(-10),
            health: .live,
            now: now
        )

        #expect(freshness.state == .delayed)
        #expect(!freshness.isLive)
        #expect(!freshness.isCriticallyDelayed)
        #expect(freshness.title == L10n.text("telemetry.delayed"))
    }

    @Test
    func refreshFailureOverridesARecentSample() {
        let freshness = TelemetryFreshness(
            refreshDate: now,
            health: .delayed(failedAttempts: 1),
            now: now
        )

        #expect(freshness.state == .delayed)
    }

    @Test
    func longDelayBecomesCritical() {
        let freshness = TelemetryFreshness(
            refreshDate: now.addingTimeInterval(-61),
            health: .live,
            now: now
        )

        #expect(freshness.state == .delayed)
        #expect(freshness.isCriticallyDelayed)
    }

    @Test
    func missingSampleKeepsWaitingAndUnavailableDistinct() {
        let waiting = TelemetryFreshness(
            refreshDate: nil,
            health: .waiting,
            now: now
        )
        let unavailable = TelemetryFreshness(
            refreshDate: nil,
            health: .unavailable(failedAttempts: 1),
            now: now
        )

        #expect(waiting.state == .waiting)
        #expect(unavailable.state == .unavailable)
    }
}
