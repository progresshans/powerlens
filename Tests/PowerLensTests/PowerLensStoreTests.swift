import Foundation
import Testing
@testable import PowerLens

struct PowerLensStoreTests {
    @Test
    @MainActor
    func insightsAreInvalidatedAfterPersistenceCompletesButNotAfterReads() async {
        let snapshot = makeTelemetrySnapshot()
        let gate = HistoryAppendGate()
        var appends = gate.arrivals.makeAsyncIterator()
        let historyStore = StubHistoryStore(appendGate: gate)
        let store = PowerLensStore(
            telemetryReader: CountingTelemetryReader(snapshot: snapshot),
            historyStore: historyStore,
            energySampler: EmptyEnergySampler(),
            startsAutomatically: false,
            now: { snapshot.timestamp }
        )

        let refresh = Task { await store.refreshOnce() }
        _ = await appends.next()
        #expect(store.latest == snapshot)
        #expect(store.historyRevision == 0)

        await gate.finish()
        await refresh.value
        #expect(store.historyRevision == 1)

        _ = await store.loadInsights(for: .all)
        await store.refreshOnce(persistImmediately: false)
        #expect(store.historyRevision == 1)
    }

    @Test
    @MainActor
    func aCancelledInsightsReadDoesNotReportAHistoryFailure() async {
        let snapshot = makeTelemetrySnapshot()
        let store = PowerLensStore(
            telemetryReader: CountingTelemetryReader(snapshot: snapshot),
            historyStore: StubHistoryStore(),
            energySampler: EmptyEnergySampler(),
            startsAutomatically: false,
            now: { snapshot.timestamp }
        )
        await store.refreshOnce()
        let revision = store.historyRevision

        let read = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.loadInsights(for: .all)
        }
        _ = await read.value

        #expect(store.historyHealth == .available)
        #expect(store.historyRevision == revision)
    }

    @Test
    @MainActor
    func insightsQueriesAllStoredDataRegardlessOfRetentionPreferences() async {
        let historyStore = StubHistoryStore()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = PowerLensStore(
            historyStore: historyStore,
            startsAutomatically: false,
            now: { now }
        )

        _ = await store.loadInsights(for: .all)

        let interval = HistoryRange.all.interval(now: now)
        #expect(await historyStore.aggregatedRanges() == [interval])
        #expect(await historyStore.rollupRanges() == [interval])
    }

    @Test
    @MainActor
    func manualRefreshDuringHistoryPreparationDoesNotPersist() async {
        let snapshot = makeTelemetrySnapshot()
        let reader = CountingTelemetryReader(snapshot: snapshot)
        let historyStore = StubHistoryStore(blocksLoad: true)
        let store = PowerLensStore(
            telemetryReader: reader,
            historyStore: historyStore,
            energySampler: EmptyEnergySampler(),
            systemCompatibilityRecorder: StubSystemCompatibilityRecorder(),
            startsAutomatically: true,
            interactiveRefreshInterval: .seconds(60),
            backgroundRefreshInterval: .seconds(60)
        )

        await historyStore.waitUntilLoadStarts()
        await store.refreshOnce(persistImmediately: true)
        let earlyHistory = store.history
        let earlyAppends = await historyStore.appendedSnapshots()

        await historyStore.finishLoading()
        await waitForAppendCount(1, in: historyStore)

        #expect(earlyHistory.isEmpty)
        #expect(earlyAppends.isEmpty)
        #expect(store.latest == snapshot)
        #expect(await historyStore.appendedSnapshots() == [snapshot.withChargingPolicyStatus(nil)])
        withExtendedLifetime(store) {}
    }

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
        #expect(store.lastRefreshAttemptAt == snapshot.timestamp.addingTimeInterval(60))
        #expect(store.telemetryHealth == .live)
        #expect(store.historyHealth == .available)
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
        #expect(store.telemetryHealth == .unavailable(failedAttempts: 1))
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
        #expect(store.telemetryHealth == .live)
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
    func refreshExplainsChargingPastAConfiguredLimitEndToEnd() async {
        let snapshot = makeTelemetrySnapshot(
            batteryLevel: 99,
            isCharging: true,
            timeToFullMinutes: 0,
            batteryCurrentA: 0.74,
            batteryPowerW: -9.4,
            adapterInputPowerW: 20.5,
            systemLoadW: 10.4,
            chargingPolicyStatus: .manualLimit(targetPercent: 80)
        )
        let store = PowerLensStore(
            telemetryReader: StubTelemetryReader(result: .init(
                snapshot: snapshot,
                activeEngine: .livePrecision
            )),
            historyStore: StubHistoryStore(),
            startsAutomatically: false
        )

        await store.refreshOnce(persistImmediately: false)

        #expect(
            store.resolvedPowerState?.managedChargingState
                == .chargingBeyondLimit(targetPercent: 80)
        )
        #expect(store.resolvedPowerState?.externalPowerState == .charging)
        #expect(store.menuBarBatteryBadge == .chargingBolt)
        #expect(
            store.latest?.statusHeadline(
                resolvedState: store.resolvedPowerState
            ) == L10n.tr(
                "status.manualLimit.chargingBeyond",
                Formatters.percent(80)
            )
        )
        #expect(
            store.diagnostics.contains {
                $0.title == L10n.tr(
                    "status.manualLimit.chargingBeyond",
                    Formatters.percent(80)
                )
                    && $0.message == L10n.text(
                        "diag.manualLimit.chargingBeyond.message"
                    )
            }
        )
        #expect(
            store.latest.map(PowerFlowPresentationModel.init)?.state
                == .charging
        )
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
                $0.kind == .powerDeliveryShortfall
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
                $0.title
                    == L10n.text("diag.powerDeliveryShortfall.title")
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
    func becomingInteractiveRefreshesImmediatelyAndRestartsTheLoop() async {
        let snapshot = makeTelemetrySnapshot()
        let reader = CountingTelemetryReader(snapshot: snapshot)
        let historicalSnapshot = snapshot.withChargingPolicyStatus(nil)
        let store = PowerLensStore(
            telemetryReader: reader,
            historyStore: StubHistoryStore(
                loadedSnapshots: [historicalSnapshot]
            ),
            energySampler: EmptyEnergySampler(),
            startsAutomatically: true,
            interactiveRefreshInterval: .seconds(60),
            backgroundRefreshInterval: .seconds(60)
        )

        await waitForSuccessfulRefresh(in: store)
        #expect(await reader.readCount() == 1)

        store.setRefreshCadence(.interactive)
        await waitForReadCount(2, in: reader)
        #expect(await reader.readCount() == 2)

        store.setRefreshCadence(.interactive)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await reader.readCount() == 2)
        withExtendedLifetime(store) {}
    }

    @Test
    @MainActor
    func becomingInteractiveDuringStartupRefreshesBeforeHistoryIsReady() async {
        let snapshot = makeTelemetrySnapshot()
        let historicalSnapshot = snapshot.withChargingPolicyStatus(nil)
        let reader = CountingTelemetryReader(snapshot: snapshot)
        let historyStore = StubHistoryStore(blocksLoad: true)
        let store = PowerLensStore(
            telemetryReader: reader,
            historyStore: historyStore,
            energySampler: EmptyEnergySampler(),
            systemCompatibilityRecorder: StubSystemCompatibilityRecorder(),
            startsAutomatically: true,
            interactiveRefreshInterval: .seconds(60),
            backgroundRefreshInterval: .seconds(60)
        )

        await historyStore.waitUntilLoadStarts()
        store.setRefreshCadence(.interactive)
        await waitForReadCount(1, in: reader)

        let readsBeforeHistoryWasReady = await reader.readCount()
        let appendsBeforeHistoryWasReady =
            await historyStore.appendedSnapshots()

        await historyStore.finishLoading()
        await waitForReadCount(2, in: reader)
        await waitForAppendCount(1, in: historyStore)

        #expect(readsBeforeHistoryWasReady == 1)
        #expect(appendsBeforeHistoryWasReady.isEmpty)
        #expect(await reader.readCount() == 2)
        #expect(
            await historyStore.appendedSnapshots()
                == [historicalSnapshot]
        )
        withExtendedLifetime(store) {}
    }

    @Test
    @MainActor
    func becomingInteractiveDoesNotSupersedeAStartupReadInFlight() async {
        let snapshot = makeTelemetrySnapshot()
        let historicalSnapshot = snapshot.withChargingPolicyStatus(nil)
        let reader = ControlledTelemetryReader()
        let historyStore = StubHistoryStore()
        let store = PowerLensStore(
            telemetryReader: reader,
            historyStore: historyStore,
            energySampler: EmptyEnergySampler(),
            systemCompatibilityRecorder: StubSystemCompatibilityRecorder(),
            startsAutomatically: true,
            interactiveRefreshInterval: .seconds(60),
            backgroundRefreshInterval: .seconds(60)
        )

        await waitForPendingReads(1, in: reader)
        store.setRefreshCadence(.interactive)
        try? await Task.sleep(for: .milliseconds(20))

        let pendingReadCount = await reader.pendingReadCount()
        let result = TelemetryReadResult(
            snapshot: snapshot,
            activeEngine: .livePrecision
        )
        if pendingReadCount > 1 {
            await reader.resumeLast(with: result)
        }
        await reader.resumeFirst(with: result)
        await waitForAppendCount(1, in: historyStore)

        #expect(pendingReadCount == 1)
        #expect(
            await historyStore.appendedSnapshots()
                == [historicalSnapshot]
        )
        withExtendedLifetime(store) {}
    }

    @Test
    @MainActor
    func retentionPreferenceChangeRequestsANewPurge() async {
        let historyStore = StubHistoryStore()
        let snapshot = makeTelemetrySnapshot()
        let store = PowerLensStore(
            telemetryReader: StubTelemetryReader(
                result: TelemetryReadResult(
                    snapshot: snapshot,
                    activeEngine: .compatible
                )
            ),
            historyStore: historyStore,
            startsAutomatically: true
        )

        for _ in 0..<200 {
            if await historyStore.purgedCutoffDates().count >= 1 {
                break
            }
            try? await Task.sleep(for: .milliseconds(5))
        }

        store.historyRetentionPreferencesChanged()

        for _ in 0..<200 {
            if await historyStore.purgedCutoffDates().count >= 2 {
                break
            }
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(await historyStore.purgedCutoffDates().count == 2)
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
        #expect(store.telemetryHealth == .unavailable(failedAttempts: 1))
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
        #expect(store.telemetryHealth == .live)
        #expect(store.latest == snapshot)
    }

    @Test
    @MainActor
    func failedRefreshAfterSuccessMarksDataDelayedAndPreservesSnapshot() async {
        let snapshot = makeTelemetrySnapshot()
        let reader = SequenceTelemetryReader(snapshots: [snapshot])
        let store = PowerLensStore(
            telemetryReader: reader,
            historyStore: StubHistoryStore(),
            startsAutomatically: false
        )

        await store.refreshOnce(persistImmediately: false)
        await store.refreshOnce(persistImmediately: false)

        #expect(store.latest == snapshot)
        #expect(store.telemetryUnavailable == false)
        #expect(store.telemetryHealth == .delayed(failedAttempts: 1))

        await store.refreshOnce(persistImmediately: false)

        #expect(store.telemetryHealth == .delayed(failedAttempts: 2))
    }

    @Test
    @MainActor
    func successfulRefreshRecoversFromUnavailableState() async {
        let snapshot = makeTelemetrySnapshot()
        let reader = OutcomeTelemetryReader(
            outcomes: [
                .unavailable,
                .success(
                    TelemetryReadResult(
                        snapshot: snapshot,
                        activeEngine: .compatible
                    )
                ),
            ]
        )
        let store = PowerLensStore(
            telemetryReader: reader,
            historyStore: StubHistoryStore(),
            startsAutomatically: false
        )

        await store.refreshOnce(persistImmediately: false)
        #expect(store.telemetryHealth == .unavailable(failedAttempts: 1))

        await store.refreshOnce(persistImmediately: false)

        #expect(store.telemetryHealth == .live)
        #expect(store.latest == snapshot)
    }

    @Test
    @MainActor
    func staleFailedRefreshDoesNotOverrideNewerSuccess() async {
        let snapshot = makeTelemetrySnapshot()
        let reader = ControlledTelemetryReader()
        let store = PowerLensStore(
            telemetryReader: reader,
            historyStore: StubHistoryStore(),
            startsAutomatically: false
        )

        let firstRefresh = Task { @MainActor in
            await store.refreshOnce(persistImmediately: false)
        }
        await waitForPendingReads(1, in: reader)
        let secondRefresh = Task { @MainActor in
            await store.refreshOnce(persistImmediately: false)
        }
        await waitForPendingReads(2, in: reader)

        await reader.resumeLast(
            with: TelemetryReadResult(
                snapshot: snapshot,
                activeEngine: .livePrecision
            )
        )
        await secondRefresh.value
        await reader.failFirst()
        await firstRefresh.value

        #expect(store.telemetryHealth == .live)
        #expect(store.latest == snapshot)
    }

    @Test
    @MainActor
    func historyAppendFailureIsVisibleWithoutInterruptingLiveTelemetry() async {
        let snapshot = makeTelemetrySnapshot()
        let historyStore = StubHistoryStore(failAppend: true)
        let store = PowerLensStore(
            telemetryReader: StubTelemetryReader(
                result: TelemetryReadResult(
                    snapshot: snapshot,
                    activeEngine: .compatible
                )
            ),
            historyStore: historyStore,
            startsAutomatically: false
        )

        await store.refreshOnce(persistImmediately: true)

        #expect(store.latest == snapshot)
        #expect(store.telemetryHealth == .live)
        #expect(store.historyHealth == .degraded)
        #expect(store.historyRevision == 0)
    }

    @Test
    @MainActor
    func compatibilityDiagnosticsStaySeparateFromSnapshotHistory() async {
        let snapshot = makeTelemetrySnapshot(
            chargingPolicyStatus: .unavailable
        )
        let diagnostic = SystemCompatibilityDiagnostic(
            subsystem: .powerUI,
            classification: .contractMismatch,
            reason: .methodMissing,
            component: "isOBCEngaged:"
        )
        let recorder = StubSystemCompatibilityRecorder()
        let historyStore = StubHistoryStore()
        let observedAt = snapshot.timestamp.addingTimeInterval(30)
        let store = PowerLensStore(
            telemetryReader: StubTelemetryReader(
                result: TelemetryReadResult(
                    snapshot: snapshot,
                    activeEngine: .compatible,
                    systemCompatibilityDiagnostics: [diagnostic]
                )
            ),
            historyStore: historyStore,
            systemCompatibilityRecorder: recorder,
            startsAutomatically: false,
            now: { observedAt }
        )

        await store.refreshOnce(persistImmediately: true)

        #expect(store.systemCompatibilityDiagnostics == [diagnostic])
        #expect(
            await recorder.recordedDiagnostics()
                == [.init(diagnostic: diagnostic, observedAt: observedAt)]
        )
        #expect(store.history == [snapshot.withChargingPolicyStatus(nil)])
        #expect(
            await historyStore.appendedSnapshots()
                == [snapshot.withChargingPolicyStatus(nil)]
        )
    }
}

private enum TelemetryOutcome: Sendable {
    case success(TelemetryReadResult)
    case unavailable
}

private actor OutcomeTelemetryReader: TelemetryReading {
    private let outcomes: [TelemetryOutcome]
    private var nextIndex = 0

    init(outcomes: [TelemetryOutcome]) {
        self.outcomes = outcomes
    }

    func readSnapshot(
        preference: TelemetryEnginePreference
    ) async throws -> TelemetryReadResult {
        guard nextIndex < outcomes.count else {
            throw TelemetryReadError.unavailable
        }

        defer { nextIndex += 1 }
        switch outcomes[nextIndex] {
        case let .success(result):
            return result
        case .unavailable:
            throw TelemetryReadError.unavailable
        }
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
    for _ in 0..<1_000 {
        if await reader.pendingReadCount() >= expectedCount {
            return
        }

        try? await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
private func waitForSuccessfulRefresh(in store: PowerLensStore) async {
    for _ in 0..<200 {
        if store.telemetryHealth == .live {
            return
        }

        try? await Task.sleep(for: .milliseconds(1))
    }
}

private func waitForReadCount(
    _ expectedCount: Int,
    in reader: CountingTelemetryReader
) async {
    for _ in 0..<200 {
        if await reader.readCount() >= expectedCount {
            return
        }

        try? await Task.sleep(for: .milliseconds(1))
    }
}

private func waitForAppendCount(
    _ expectedCount: Int,
    in historyStore: StubHistoryStore
) async {
    for _ in 0..<200 {
        if await historyStore.appendedSnapshots().count >= expectedCount {
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

private actor CountingTelemetryReader: TelemetryReading {
    private let snapshot: TelemetrySnapshot
    private var count = 0

    init(snapshot: TelemetrySnapshot) {
        self.snapshot = snapshot
    }

    func readSnapshot(
        preference: TelemetryEnginePreference
    ) async throws -> TelemetryReadResult {
        count += 1
        return TelemetryReadResult(
            snapshot: snapshot,
            activeEngine: .livePrecision
        )
    }

    func readCount() -> Int {
        count
    }
}

private actor EmptyEnergySampler: ProcessEnergySampling {
    func sample(now: Date) async -> [AppEnergyUsage] {
        []
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

    func failFirst() {
        continuations.removeFirst().resume(
            throwing: TelemetryReadError.unavailable
        )
    }
}

private actor StubHistoryStore: HistoryStoring {
    private var appended: [TelemetrySnapshot] = []
    private var purgedCutoffs: [Date] = []
    private var requestedAggregatedRanges: [DateInterval] = []
    private var requestedRollupRanges: [DateInterval] = []
    private let failAppend: Bool
    private let loadedSnapshots: [TelemetrySnapshot]
    private let blocksLoad: Bool
    private let appendGate: HistoryAppendGate?
    private var loadStarted = false
    private var loadStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var loadContinuation: CheckedContinuation<Void, Never>?

    init(
        failAppend: Bool = false,
        loadedSnapshots: [TelemetrySnapshot] = [],
        blocksLoad: Bool = false,
        appendGate: HistoryAppendGate? = nil
    ) {
        self.failAppend = failAppend
        self.loadedSnapshots = loadedSnapshots
        self.blocksLoad = blocksLoad
        self.appendGate = appendGate
    }

    func loadRecent(
        since cutoffDate: Date
    ) async throws -> [TelemetrySnapshot] {
        if blocksLoad {
            loadStarted = true
            loadStartWaiters.forEach { $0.resume() }
            loadStartWaiters.removeAll()

            await withCheckedContinuation { continuation in
                loadContinuation = continuation
            }
        }

        return loadedSnapshots
    }

    func append(_ snapshot: TelemetrySnapshot) async throws {
        if let appendGate {
            await appendGate.suspend()
        }
        if failAppend {
            throw StubHistoryError.writeFailed
        }
        appended.append(snapshot)
    }

    func purge(
        olderThan cutoffDate: Date,
        rollupBucketSeconds: Int?
    ) async throws {
        purgedCutoffs.append(cutoffDate)
    }

    func summary(for range: DateInterval) async throws -> HistorySummary {
        .empty(range: range)
    }

    func aggregatedSeries(
        for range: DateInterval,
        bucketSeconds: Int
    ) async throws -> [AggregatedTelemetryPoint] {
        requestedAggregatedRanges.append(range)
        return []
    }

    func rollupSeries(
        for range: DateInterval
    ) async throws -> [AggregatedTelemetryPoint] {
        requestedRollupRanges.append(range)
        return []
    }

    func batteryHealthTrend(
        since cutoffDate: Date
    ) async throws -> [BatteryHealthPoint] {
        []
    }

    func appendedSnapshots() -> [TelemetrySnapshot] {
        appended
    }

    func purgedCutoffDates() -> [Date] {
        purgedCutoffs
    }

    func aggregatedRanges() -> [DateInterval] {
        requestedAggregatedRanges
    }

    func rollupRanges() -> [DateInterval] {
        requestedRollupRanges
    }

    func waitUntilLoadStarts() async {
        guard !loadStarted else {
            return
        }

        await withCheckedContinuation { continuation in
            loadStartWaiters.append(continuation)
        }
    }

    func finishLoading() {
        loadContinuation?.resume()
        loadContinuation = nil
    }
}

private actor HistoryAppendGate {
    let arrivals: AsyncStream<Void>
    private let arrived: AsyncStream<Void>.Continuation
    private var continuation: CheckedContinuation<Void, Never>?

    init() {
        (arrivals, arrived) = AsyncStream.makeStream(of: Void.self)
    }

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            arrived.yield(())
        }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

private enum StubHistoryError: Error {
    case writeFailed
}

private actor StubSystemCompatibilityRecorder: SystemCompatibilityRecording {
    struct Entry: Equatable, Sendable {
        let diagnostic: SystemCompatibilityDiagnostic
        let observedAt: Date
    }

    private var entries: [Entry] = []

    func record(
        _ diagnostic: SystemCompatibilityDiagnostic,
        observedAt: Date
    ) async {
        entries.append(Entry(diagnostic: diagnostic, observedAt: observedAt))
    }

    func recordedDiagnostics() -> [Entry] {
        entries
    }
}
