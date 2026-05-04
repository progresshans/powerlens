import Foundation
import Testing
@testable import PowerLens

struct PowerLensStoreTests {
    @Test
    @MainActor
    func refreshOnceUpdatesStateAndPersistsWhenRequested() async {
        let snapshot = makeTelemetrySnapshot(
            batteryPowerW: 4.2,
            adapterInputPowerW: 12.5,
            systemLoadW: 16.7
        )
        let historyStore = StubHistoryStore()
        let store = PowerLensStore(
            telemetryReader: StubTelemetryReader(result: TelemetryReadResult(snapshot: snapshot, activeEngine: .livePrecision)),
            historyStore: historyStore,
            startsAutomatically: false,
            now: { snapshot.timestamp.addingTimeInterval(60) }
        )

        await store.refreshOnce(persistImmediately: true)

        #expect(store.latest == snapshot)
        #expect(store.activeTelemetryEngine == .livePrecision)
        #expect(store.lastRefreshAt == snapshot.timestamp)
        #expect(store.history == [snapshot])
        #expect(await historyStore.appendedSnapshots() == [snapshot])
    }

    @Test
    @MainActor
    func refreshFailureKeepsExistingState() async {
        let historyStore = StubHistoryStore()
        let store = PowerLensStore(
            telemetryReader: StubTelemetryReader(error: TelemetryReadError.unavailable),
            historyStore: historyStore,
            startsAutomatically: false
        )

        await store.refreshOnce(persistImmediately: true)

        #expect(store.latest == nil)
        #expect(store.history.isEmpty)
        #expect(await historyStore.appendedSnapshots().isEmpty)
    }

    @Test
    @MainActor
    func staleRefreshResultDoesNotOverwriteNewerSnapshot() async {
        let olderSnapshot = makeTelemetrySnapshot(
            batteryPowerW: 1,
            adapterInputPowerW: 10,
            systemLoadW: 11
        )
        let newerSnapshot = makeTelemetrySnapshot(
            batteryPowerW: 2,
            adapterInputPowerW: 20,
            systemLoadW: 22
        )
        let telemetryReader = ControlledTelemetryReader()
        let historyStore = StubHistoryStore()
        let store = PowerLensStore(
            telemetryReader: telemetryReader,
            historyStore: historyStore,
            startsAutomatically: false,
            now: { newerSnapshot.timestamp.addingTimeInterval(60) }
        )

        let firstRefresh = Task { @MainActor in
            await store.refreshOnce(persistImmediately: true)
        }
        await waitForPendingReads(1, in: telemetryReader)

        let secondRefresh = Task { @MainActor in
            await store.refreshOnce(persistImmediately: true)
        }
        await waitForPendingReads(2, in: telemetryReader)

        await telemetryReader.resumeLast(with: TelemetryReadResult(
            snapshot: newerSnapshot,
            activeEngine: .livePrecision
        ))
        await secondRefresh.value

        await telemetryReader.resumeFirst(with: TelemetryReadResult(
            snapshot: olderSnapshot,
            activeEngine: .compatible
        ))
        await firstRefresh.value

        #expect(store.latest == newerSnapshot)
        #expect(store.activeTelemetryEngine == .livePrecision)
        #expect(store.history == [newerSnapshot])
        #expect(await historyStore.appendedSnapshots() == [newerSnapshot])
    }

    @Test
    @MainActor
    func menuBarBatteryBadgeShowsPlugImmediatelyWhenExternalPowerIsConnected() async {
        let connectedSnapshot = makeTelemetrySnapshot(
            batteryLevel: 80,
            batteryCurrentA: -0.4,
            batteryPowerW: 3.8,
            adapterInputPowerW: 12,
            systemLoadW: 15.8
        )
        let store = PowerLensStore(
            telemetryReader: StubTelemetryReader(result: TelemetryReadResult(
                snapshot: connectedSnapshot,
                activeEngine: .livePrecision
            )),
            historyStore: StubHistoryStore(),
            startsAutomatically: false
        )

        await store.refreshOnce(persistImmediately: false)

        #expect(store.menuBarBatteryBadge == .pluggedHolding)
    }
}

private func waitForPendingReads(_ expectedCount: Int, in reader: ControlledTelemetryReader) async {
    for _ in 0..<100 {
        if await reader.pendingReadCount() >= expectedCount {
            return
        }

        try? await Task.sleep(for: .milliseconds(1))
    }
}

private actor StubTelemetryReader: TelemetryReading {
    let result: TelemetryReadResult?
    let error: Error?

    init(result: TelemetryReadResult) {
        self.result = result
        self.error = nil
    }

    init(error: Error) {
        self.result = nil
        self.error = error
    }

    func readSnapshot(preference: TelemetryEnginePreference) async throws -> TelemetryReadResult {
        if let error {
            throw error
        }

        guard let result else {
            throw TelemetryReadError.unavailable
        }

        return result
    }
}

private actor ControlledTelemetryReader: TelemetryReading {
    private var continuations: [CheckedContinuation<TelemetryReadResult, any Error>] = []

    func readSnapshot(preference: TelemetryEnginePreference) async throws -> TelemetryReadResult {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func pendingReadCount() -> Int {
        continuations.count
    }

    func resumeFirst(with result: TelemetryReadResult) {
        continuations.removeFirst().resume(returning: result)
    }

    func resumeLast(with result: TelemetryReadResult) {
        continuations.removeLast().resume(returning: result)
    }
}

private actor StubHistoryStore: HistoryStoring {
    private var appended: [TelemetrySnapshot] = []

    func loadRecent(since cutoffDate: Date) async -> [TelemetrySnapshot] {
        []
    }

    func append(_ snapshot: TelemetrySnapshot) async {
        appended.append(snapshot)
    }

    func appendedSnapshots() -> [TelemetrySnapshot] {
        appended
    }
}
