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
            systemLoadW: 16.7,
            chargingPolicyStatus: .manualLimit(targetPercent: 87)
        )
        let historicalSnapshot = snapshot.withChargingPolicyStatus(nil)
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
        #expect(store.history == [historicalSnapshot])
        #expect(await historyStore.appendedSnapshots() == [historicalSnapshot])
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

    @Test
    @MainActor
    func managedHoldSurvivesTransientAssistButReportsSustainedShortfall() async {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let calm = { (seconds: TimeInterval) in
            makeTelemetrySnapshot(
                timestamp: start.addingTimeInterval(seconds),
                batteryLevel: 80,
                isCharging: false,
                batteryCurrentA: 0,
                batteryPowerW: 0,
                adapterInputPowerW: 20,
                systemLoadW: 20,
                adapterMaxPowerW: 96,
                chargingPolicyStatus: .manualLimit(targetPercent: 80)
            )
        }
        let assist = { (seconds: TimeInterval) in
            makeTelemetrySnapshot(
                timestamp: start.addingTimeInterval(seconds),
                batteryLevel: 80,
                isCharging: true,
                batteryCurrentA: -1.5,
                batteryPowerW: 18,
                adapterInputPowerW: 20,
                systemLoadW: 38,
                adapterMaxPowerW: 96,
                chargingPolicyStatus: .manualLimit(targetPercent: 80)
            )
        }
        let reader = SequenceTelemetryReader(
            snapshots: [
                calm(0),
                calm(12),
                assist(15),
                assist(24),
                assist(30),
            ]
        )
        let store = PowerLensStore(
            telemetryReader: reader,
            historyStore: StubHistoryStore(),
            startsAutomatically: false
        )

        await store.refreshOnce(persistImmediately: false)
        await store.refreshOnce(persistImmediately: false)

        #expect(
            store.resolvedPowerState?.managedChargingState
                == .holdingAtLimit(targetPercent: 80)
        )
        #expect(store.resolvedPowerState?.externalPowerState == .holding)

        await store.refreshOnce(persistImmediately: false)

        #expect(store.resolvedPowerState?.batteryFlowEvidence == .discharging)
        #expect(
            store.resolvedPowerState?.powerDeliveryState
                == .transientBatteryAssist
        )
        #expect(
            store.resolvedPowerState?.managedChargingState
                == .holdingAtLimit(targetPercent: 80)
        )
        #expect(store.resolvedPowerState?.externalPowerState == .holding)
        #expect(store.menuBarBatteryBadge == .pluggedHolding)
        #expect(store.menuBarSymbolName == "pause.circle.fill")
        #expect(
            store.latest?.statusSubheadline(
                resolvedState: store.resolvedPowerState
            ) == L10n.text(
                "status.subheadline.manualLimit.transientAssist"
            )
        )
        #expect(
            !store.diagnostics.contains {
                TelemetrySnapshot.powerDiagnosticTitles.contains($0.title)
            }
        )
        #expect(
            store.latest.map(PowerFlowPresentationModel.init)?.state
                == .underpowered
        )

        await store.refreshOnce(persistImmediately: false)
        await store.refreshOnce(persistImmediately: false)

        #expect(
            store.resolvedPowerState?.powerDeliveryState
                == .sustainedShortfall
        )
        #expect(
            store.resolvedPowerState?.managedChargingState
                == .limitConfigured(targetPercent: 80)
        )
        #expect(store.resolvedPowerState?.externalPowerState == .connected)
        #expect(store.menuBarSymbolName == "exclamationmark.triangle.fill")
        #expect(
            store.diagnostics.contains {
                $0.title == L10n.text("diag.slowCharger.title")
            }
        )
    }

    @Test
    @MainActor
    func startupPurgesHistoryOnce() async {
        let historyStore = StubHistoryStore()
        let snapshot = makeTelemetrySnapshot(
            batteryPowerW: 1,
            adapterInputPowerW: 10,
            systemLoadW: 11
        )
        let store = PowerLensStore(
            telemetryReader: StubTelemetryReader(result: TelemetryReadResult(snapshot: snapshot, activeEngine: .compatible)),
            historyStore: historyStore,
            startsAutomatically: true
        )

        for _ in 0..<200 {
            if await historyStore.purgedCutoffDates().count >= 1 {
                break
            }
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(await historyStore.purgedCutoffDates().count == 1)
        withExtendedLifetime(store) {}
    }

    @Test
    @MainActor
    func telemetryUnavailableSetWhenReadFailsWithNoData() async {
        let store = PowerLensStore(
            telemetryReader: StubTelemetryReader(error: TelemetryReadError.unavailable),
            historyStore: StubHistoryStore(),
            startsAutomatically: false
        )

        await store.refreshOnce(persistImmediately: true)

        #expect(store.telemetryUnavailable)
        #expect(store.latest == nil)
    }

    @Test
    @MainActor
    func telemetryUnavailableClearsAfterSuccessfulRead() async {
        let snapshot = makeTelemetrySnapshot()
        let store = PowerLensStore(
            telemetryReader: StubTelemetryReader(result: TelemetryReadResult(snapshot: snapshot, activeEngine: .compatible)),
            historyStore: StubHistoryStore(),
            startsAutomatically: false
        )

        await store.refreshOnce(persistImmediately: true)

        #expect(store.telemetryUnavailable == false)
        #expect(store.latest == snapshot)
    }
}

private actor SequenceTelemetryReader: TelemetryReading {
    private let snapshots: [TelemetrySnapshot]
    private var nextIndex = 0

    init(snapshots: [TelemetrySnapshot]) {
        self.snapshots = snapshots
    }

    func readSnapshot(
        preference: TelemetryEnginePreference
    ) async throws -> TelemetryReadResult {
        guard nextIndex < snapshots.count else {
            throw TelemetryReadError.unavailable
        }

        defer { nextIndex += 1 }
        return TelemetryReadResult(
            snapshot: snapshots[nextIndex],
            activeEngine: .livePrecision
        )
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
    private var purgedCutoffs: [Date] = []

    func loadRecent(since cutoffDate: Date) async -> [TelemetrySnapshot] {
        []
    }

    func append(_ snapshot: TelemetrySnapshot) async {
        appended.append(snapshot)
    }

    func purge(olderThan cutoffDate: Date, rollupBucketSeconds: Int?) async {
        purgedCutoffs.append(cutoffDate)
    }

    func summary(for range: DateInterval) async -> HistorySummary {
        .empty(range: range)
    }

    func aggregatedSeries(for range: DateInterval, bucketSeconds: Int) async -> [AggregatedTelemetryPoint] {
        []
    }

    func rollupSeries(for range: DateInterval) async -> [AggregatedTelemetryPoint] {
        []
    }

    func batteryHealthTrend(since cutoffDate: Date) async -> [BatteryHealthPoint] {
        []
    }

    func appendedSnapshots() -> [TelemetrySnapshot] {
        appended
    }

    func purgedCutoffDates() -> [Date] {
        purgedCutoffs
    }
}
