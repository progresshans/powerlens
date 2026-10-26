import Combine
import Foundation
import Testing
@testable import PowerLens

struct PowerLensStoreTests {
    @Test
    @MainActor
    func energyModeIsReadAgainWhenThePowerSourceChanges() async {
        // High Power on the charger and Automatic on battery leave Low Power
        // Mode off in both states, so only the source change can trigger this.
        let start = Date(timeIntervalSince1970: 1_775_000_000)
        let charger = makeTelemetrySnapshot(timestamp: start)
        let reader = StubEnergyModeReader([.highPower, .automatic])
        let store = PowerLensStore(
            telemetryReader: CountingTelemetryReader(snapshot: charger),
            historyStore: StubHistoryStore(),
            energySampler: EmptyEnergySampler(),
            energyModeReader: reader,
            startsAutomatically: false,
            now: { start }
        )
        await store.refreshOnce()

        store.setRefreshCadence(.interactive)
        await store.energyModeTask?.value
        #expect(store.energyMode == .highPower)

        store.receivePowerSourceObservation(
            .init(externalConnected: false, observedAt: start.addingTimeInterval(1)),
            reason: .powerSourceChanged
        )
        await store.energyModeTask?.value
        #expect(store.energyMode == .automatic)
    }

    @Test
    @MainActor
    func energyModeIsReadOnLowPowerChangesAndManualRefreshOnly() async {
        let start = Date(timeIntervalSince1970: 1_775_000_000)
        let normal = makeTelemetrySnapshot(timestamp: start)
        let lowPower = makeTelemetrySnapshot(timestamp: start.addingTimeInterval(3), lowPowerModeEnabled: true)
        let reader = StubEnergyModeReader([.lowPower])
        let store = PowerLensStore(
            telemetryReader: SequenceTelemetryReader(snapshots: [normal, normal, normal, lowPower]),
            historyStore: StubHistoryStore(),
            energySampler: EmptyEnergySampler(),
            energyModeReader: reader,
            startsAutomatically: false,
            now: { start }
        )

        // Ordinary telemetry ticks do not run pmset.
        await store.refreshOnce()
        await store.refreshOnce()
        await store.refreshOnce()
        #expect(await reader.readCount == 0)

        await store.refreshOnce()
        await store.energyModeTask?.value
        #expect(await reader.readCount == 1)
        #expect(store.energyMode == .lowPower)

        store.refreshNow()
        await store.energyModeTask?.value
        #expect(await reader.readCount == 2)
    }

    @Test
    @MainActor
    func recentPowerHistoryReadsSavedHistoryAsBalancedReadings() async {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let charging = makeTelemetrySnapshot(
            timestamp: now.addingTimeInterval(-120),
            isCharging: true,
            batteryCurrentA: 3.44,
            batteryPowerW: -46.4,
            adapterInputPowerW: 53.6,
            systemLoadW: 7.2
        )
        let onBattery = makeTelemetrySnapshot(
            timestamp: now.addingTimeInterval(-60),
            powerSource: .battery,
            externalConnected: false,
            timeToEmptyMinutes: 240,
            batteryCurrentA: -0.82,
            batteryPowerW: 9.1,
            adapterInputPowerW: 0,
            systemLoadW: 9.1,
            adapterMaxPowerW: nil
        )
        let store = PowerLensStore(
            telemetryReader: CountingTelemetryReader(snapshot: onBattery),
            historyStore: StubHistoryStore(loadedSnapshots: [charging, onBattery]),
            energySampler: EmptyEnergySampler(),
            startsAutomatically: false,
            now: { now }
        )

        let samples = await store.recentPowerHistory()

        #expect(samples.map(\.date) == [charging.timestamp, onBattery.timestamp])
        #expect(abs((samples.first?.inputW ?? 0) - 53.6) < 0.05)
        #expect(abs((samples.first?.systemW ?? 0) - 7.2) < 0.05)
        // On battery the charger contributes nothing, not "unknown".
        #expect(samples.last?.inputW == 0)
        #expect(abs((samples.last?.systemW ?? 0) - 9.1) < 0.05)
    }

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
        let earlyAppends = await historyStore.appendedSnapshots()

        await historyStore.finishLoading()
        await waitForAppendCount(1, in: historyStore)

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

        store.refreshNow()
        #expect(await telemetryReader.pendingReadCount() == 1)
        await telemetryReader.resumeFirst(with: TelemetryReadResult(
            snapshot: olderSnapshot,
            activeEngine: .compatible
        ))
        await waitForControlledReadCount(2, in: telemetryReader)
        #expect(store.latest == nil)

        await telemetryReader.resumeFirst(with: TelemetryReadResult(
            snapshot: newerSnapshot,
            activeEngine: .livePrecision
        ))
        await firstRefresh.value

        #expect(store.latest == newerSnapshot)
        #expect(store.telemetryHealth == .live)
        #expect(store.activeTelemetryEngine == .livePrecision)
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
        store.refreshNow()
        #expect(await reader.pendingReadCount() == 1)
        await reader.failFirst()
        await waitForControlledReadCount(2, in: reader)
        #expect(store.telemetryHealth == .waiting)
        await reader.resumeFirst(with: TelemetryReadResult(
            snapshot: snapshot,
            activeEngine: .livePrecision
        ))
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
        #expect(
            await historyStore.appendedSnapshots()
                == [snapshot.withChargingPolicyStatus(nil)]
        )
    }

    @Test
    @MainActor
    func sourceEventPublishesImmediatelyWithoutInventingFreshMeasurements() async {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let battery = makeTelemetrySnapshot(
            timestamp: start, powerSource: .battery, externalConnected: false,
            batteryCurrentA: -1.49, batteryPowerW: 15.2,
            adapterInputPowerW: 0, systemLoadW: 13.5
        )
        let connected = makeTelemetrySnapshot(
            timestamp: start.addingTimeInterval(2), batteryCurrentA: -1,
            batteryPowerW: 12, adapterInputPowerW: 5, systemLoadW: 17
        )
        let reader = ControlledTelemetryReader()
        let history = StubHistoryStore()
        let sampler = CountingEnergySampler()
        let store = PowerLensStore(
            telemetryReader: reader, historyStore: history, energySampler: sampler,
            systemCompatibilityRecorder: StubSystemCompatibilityRecorder(),
            startsAutomatically: false, now: { start }
        )
        let initial = Task { await store.refreshOnce(persistImmediately: false) }
        await waitForPendingReads(1, in: reader)
        await reader.resumeFirst(with: .init(snapshot: battery, activeEngine: .livePrecision))
        await initial.value
        let oldDiagnostics = store.diagnostics
        let oldResolvedState = store.resolvedPowerState
        let oldRefreshAttempt = store.lastRefreshAttemptAt
        var presentations: [MenuBarPresentation] = []
        let subscription = store.$menuBarPresentation.sink { presentations.append($0) }

        store.receivePowerSourceObservation(
            .init(externalConnected: true, observedAt: start.addingTimeInterval(1)),
            reason: .powerSourceChanged
        )
        #expect(presentations.last?.batteryBadge == .pluggedHolding)
        #expect(store.menuBarBatteryBadge == .pluggedHolding)
        #expect(store.latest == battery)
        #expect(store.menuBarPresentation.snapshot == battery)
        #expect(store.lastRefreshAt == start)
        #expect(store.lastRefreshAttemptAt == oldRefreshAttempt)
        #expect(store.telemetryHealth == .delayed(failedAttempts: 0))
        #expect(store.telemetryStatusText == L10n.text("telemetry.status.sourceTransition"))
        #expect(TelemetryFreshness(
            refreshDate: store.lastRefreshAt, health: store.telemetryHealth,
            now: start.addingTimeInterval(1)
        ).state == .delayed)
        #expect(store.diagnostics == oldDiagnostics)
        #expect(store.resolvedPowerState == oldResolvedState)
        #expect(await history.appendedSnapshots() == [battery])
        #expect(await sampler.sampleCount == 0)

        await waitForControlledReadCount(2, in: reader)
        await reader.resumeFirst(with: .init(snapshot: connected, activeEngine: .livePrecision))
        await waitForSnapshot(connected, in: store)
        #expect(store.telemetryHealth == .live)
        #expect(store.menuBarBatteryBadge == .pluggedHolding)
        #expect(await history.appendedSnapshots() == [battery])
        withExtendedLifetime(subscription) {}
    }

    @Test(arguments: [PowerSourceObservationReason.powerSourceChanged, .wake])
    @MainActor
    func unplugInvalidatesAnInFlightReadAndPreservesManualPersistence(reason: PowerSourceObservationReason) async {
        let charging = makeTelemetrySnapshot(isCharging: true, batteryCurrentA: 1, batteryPowerW: -12)
        let battery = makeTelemetrySnapshot(
            timestamp: charging.timestamp.addingTimeInterval(1), powerSource: .battery,
            externalConnected: false, batteryCurrentA: -1, batteryPowerW: 12,
            adapterInputPowerW: 0, systemLoadW: 11
        )
        let reader = ControlledTelemetryReader()
        let history = StubHistoryStore()
        let store = PowerLensStore(
            telemetryReader: reader, historyStore: history, energySampler: EmptyEnergySampler(),
            startsAutomatically: false
        )
        let initial = Task { await store.refreshOnce() }
        await waitForPendingReads(1, in: reader)
        await reader.resumeFirst(with: .init(snapshot: charging, activeEngine: .livePrecision))
        await initial.value
        #expect(store.menuBarBatteryBadge == .chargingBolt)

        let manual = Task { await store.refreshOnce() }
        await waitForControlledReadCount(2, in: reader)
        store.receivePowerSourceObservation(
            .init(externalConnected: false, observedAt: battery.timestamp), reason: reason
        )
        #expect(store.menuBarBatteryBadge == .none)
        #expect(store.latest == charging)
        #expect(store.telemetryHealth == .delayed(failedAttempts: 0))
        await reader.resumeFirst(with: .init(snapshot: charging, activeEngine: .livePrecision))
        await waitForControlledReadCount(3, in: reader)
        #expect(store.menuBarBatteryBadge == .none)
        #expect(await history.appendedSnapshots() == [charging])
        await reader.resumeFirst(with: .init(snapshot: battery, activeEngine: .livePrecision))
        await manual.value
        #expect(store.latest == battery)
        #expect(store.telemetryHealth == .live)
        #expect(await history.appendedSnapshots() == [charging, battery])
    }

    @Test
    @MainActor
    func sourceEventBurstHasOnlyOneReadAndOnePendingRead() async {
        let reader = ControlledTelemetryReader()
        let battery = makeTelemetrySnapshot(powerSource: .battery, externalConnected: false)
        let store = PowerLensStore(
            telemetryReader: reader, historyStore: StubHistoryStore(),
            energySampler: EmptyEnergySampler(), startsAutomatically: false
        )
        let first = Task { await store.refreshOnce(persistImmediately: false) }
        await waitForPendingReads(1, in: reader)
        for i in 0..<20 {
            store.receivePowerSourceObservation(
                .init(externalConnected: i.isMultiple(of: 2), observedAt: battery.timestamp),
                reason: .powerSourceChanged
            )
        }
        #expect(store.menuBarBatteryBadge == .none)
        #expect(store.telemetryHealth == .waiting)
        #expect(await reader.readCount() == 1)
        await reader.resumeFirst(with: .init(snapshot: makeTelemetrySnapshot(), activeEngine: .livePrecision))
        await waitForControlledReadCount(2, in: reader)
        #expect(store.latest == nil)
        await reader.resumeFirst(with: .init(snapshot: battery, activeEngine: .livePrecision))
        await first.value
        #expect(store.latest == battery)
        #expect(await reader.readCount() == 2)
    }

    @Test
    @MainActor
    func laggingRegistryDoesNotUndoEventAndGetsOneBoundedRetry() async {
        let battery = makeTelemetrySnapshot(powerSource: .battery, externalConnected: false)
        let connected = makeTelemetrySnapshot(timestamp: battery.timestamp.addingTimeInterval(1))
        let reader = ControlledTelemetryReader()
        let history = StubHistoryStore()
        let store = PowerLensStore(
            telemetryReader: reader, historyStore: history, energySampler: EmptyEnergySampler(),
            startsAutomatically: false,
            powerSourceReader: { .init(externalConnected: true, observedAt: connected.timestamp) }
        )
        store.receivePowerSourceObservation(
            .init(externalConnected: true, observedAt: connected.timestamp), reason: .initial
        )
        #expect(store.menuBarBatteryBadge == .pluggedHolding)
        #expect(store.menuBarPresentation.snapshot == nil)
        #expect(store.telemetryHealth == .waiting)
        await waitForControlledReadCount(1, in: reader)
        await reader.resumeFirst(with: .init(snapshot: battery, activeEngine: .livePrecision))
        await waitForControlledReadCount(2, in: reader)
        #expect(store.latest == nil)
        #expect(store.lastRefreshAt == nil)
        #expect(store.telemetryHealth == .unavailable(failedAttempts: 1))
        #expect(store.menuBarBatteryBadge == .pluggedHolding)
        #expect(await history.appendedSnapshots().isEmpty)
        await reader.resumeFirst(with: .init(snapshot: connected, activeEngine: .livePrecision))
        await waitForSnapshot(connected, in: store)
        #expect(await reader.readCount() == 2)
    }

    @Test
    @MainActor
    func repeatedSourceMismatchesMarkRecentTelemetryDelayedUntilRecovery() async {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let battery = makeTelemetrySnapshot(
            timestamp: start, powerSource: .battery, externalConnected: false
        )
        let connected = makeTelemetrySnapshot(timestamp: start.addingTimeInterval(2))
        let reader = ControlledTelemetryReader()
        let history = StubHistoryStore()
        let store = PowerLensStore(
            telemetryReader: reader, historyStore: history, energySampler: EmptyEnergySampler(),
            startsAutomatically: false, now: { start.addingTimeInterval(2) },
            powerSourceReader: { .init(externalConnected: true, observedAt: connected.timestamp) }
        )
        let initial = Task { await store.refreshOnce(persistImmediately: false) }
        await waitForPendingReads(1, in: reader)
        await reader.resumeFirst(with: .init(snapshot: battery, activeEngine: .livePrecision))
        await initial.value
        #expect(store.telemetryHealth == .live)

        store.receivePowerSourceObservation(
            .init(externalConnected: true, observedAt: connected.timestamp), reason: .powerSourceChanged
        )
        await waitForControlledReadCount(2, in: reader)
        await reader.resumeFirst(with: .init(snapshot: battery, activeEngine: .livePrecision))
        await waitForControlledReadCount(3, in: reader)
        #expect(store.telemetryHealth == .delayed(failedAttempts: 1))
        await reader.resumeFirst(with: .init(snapshot: battery, activeEngine: .livePrecision))
        await waitForTelemetryHealth(.delayed(failedAttempts: 2), in: store)

        #expect(store.telemetryHealth == .delayed(failedAttempts: 2))
        #expect(store.latest == battery)
        #expect(store.lastRefreshAt == start)
        #expect(store.lastRefreshAttemptAt == start.addingTimeInterval(2))
        #expect(TelemetryFreshness(
            refreshDate: store.lastRefreshAt, health: store.telemetryHealth,
            now: start.addingTimeInterval(2)
        ).state == .delayed)
        #expect(await history.appendedSnapshots() == [battery])

        let recovery = Task { await store.refreshOnce(persistImmediately: false) }
        await waitForControlledReadCount(4, in: reader)
        await reader.resumeFirst(with: .init(snapshot: connected, activeEngine: .livePrecision))
        await recovery.value
        #expect(store.telemetryHealth == .live)
        #expect(store.latest == connected)
        #expect(store.lastRefreshAt == connected.timestamp)
    }

    @Test
    @MainActor
    func sourceTransitionPreservesExistingFailureCountUntilMatchingTelemetryArrives() async {
        let connected = makeTelemetrySnapshot()
        let battery = makeTelemetrySnapshot(
            timestamp: connected.timestamp.addingTimeInterval(1),
            powerSource: .battery, externalConnected: false
        )
        let reader = OutcomeTelemetryReader(outcomes: [
            .success(.init(snapshot: connected, activeEngine: .livePrecision)),
            .unavailable,
            .success(.init(snapshot: battery, activeEngine: .livePrecision)),
        ])
        let store = PowerLensStore(
            telemetryReader: reader, historyStore: StubHistoryStore(), energySampler: EmptyEnergySampler(),
            startsAutomatically: false
        )
        await store.refreshOnce(persistImmediately: false)
        await store.refreshOnce(persistImmediately: false)
        let lastAttempt = store.lastRefreshAttemptAt
        #expect(store.telemetryHealth == .delayed(failedAttempts: 1))

        store.receivePowerSourceObservation(
            .init(externalConnected: false, observedAt: battery.timestamp), reason: .powerSourceChanged
        )
        #expect(store.telemetryHealth == .delayed(failedAttempts: 1))
        #expect(store.lastRefreshAttemptAt == lastAttempt)
        #expect(store.latest == connected)

        await waitForSnapshot(battery, in: store)
        #expect(store.telemetryHealth == .live)
        #expect(store.telemetryHealth.failedAttempts == 0)
    }

    @Test
    @MainActor
    func pollingReconcilesAMissedNotificationUsingFreshPowerSourceState() async {
        let connected = makeTelemetrySnapshot()
        let battery = makeTelemetrySnapshot(
            timestamp: connected.timestamp.addingTimeInterval(1), powerSource: .battery,
            externalConnected: false, batteryCurrentA: -1, batteryPowerW: 12,
            adapterInputPowerW: 0, systemLoadW: 12
        )
        let reader = SequenceTelemetryReader(snapshots: [connected, battery])
        let store = PowerLensStore(
            telemetryReader: reader, historyStore: StubHistoryStore(), energySampler: EmptyEnergySampler(),
            startsAutomatically: false,
            powerSourceReader: { .init(externalConnected: false, observedAt: battery.timestamp) }
        )
        store.receivePowerSourceObservation(
            .init(externalConnected: true, observedAt: connected.timestamp), reason: .initial
        )
        await waitForSnapshot(connected, in: store)
        await store.refreshOnce(persistImmediately: false)
        #expect(store.latest == battery)
        #expect(store.menuBarBatteryBadge == .none)
        #expect(store.resolvedPowerState?.externalPowerState == .onBattery)
    }

    @Test
    @MainActor
    func wakeRefreshesEvenWhenThePowerSourceIsUnchanged() async {
        let snapshot = makeTelemetrySnapshot()
        let reader = CountingTelemetryReader(snapshot: snapshot)
        let store = PowerLensStore(
            telemetryReader: reader, historyStore: StubHistoryStore(), energySampler: EmptyEnergySampler(),
            startsAutomatically: false
        )
        await store.refreshOnce(persistImmediately: false)
        store.receivePowerSourceObservation(
            .init(externalConnected: true, observedAt: snapshot.timestamp), reason: .wake
        )
        await waitForReadCount(2, in: reader)
        #expect(await reader.readCount() == 2)
    }

    @Test(arguments: [false, true])
    @MainActor
    func unchangedWakePreservesResolvedMenuStateWhenRefreshesFail(shortfall: Bool) async {
        let snapshot = makeTelemetrySnapshot(
            isCharging: !shortfall,
            batteryCurrentA: shortfall ? -1.5 : 1,
            batteryPowerW: shortfall ? 18 : -12,
            adapterInputPowerW: shortfall ? 20 : 22,
            systemLoadW: shortfall ? 38 : 10
        )
        let reader = OutcomeTelemetryReader(outcomes: [
            .success(.init(snapshot: snapshot, activeEngine: .livePrecision)),
            .unavailable, .unavailable,
        ])
        let store = PowerLensStore(
            telemetryReader: reader, historyStore: StubHistoryStore(), energySampler: EmptyEnergySampler(),
            startsAutomatically: false,
            powerStateConfiguration: .init(transientAssistGrace: 0, shortfallEvidenceConfirmation: 0)
        )
        await store.refreshOnce(persistImmediately: false)
        let presentation = store.menuBarPresentation
        let resolvedState = store.resolvedPowerState
        #expect(presentation.symbolName == (shortfall ? "exclamationmark.triangle.fill" : "bolt.fill"))

        store.receivePowerSourceObservation(
            .init(externalConnected: true, observedAt: snapshot.timestamp), reason: .wake
        )
        #expect(store.menuBarPresentation == presentation)
        #expect(store.telemetryHealth == .live)
        store.refreshMenuBarLocalization()
        #expect(store.menuBarPresentation == presentation)

        await waitForTelemetryHealth(.delayed(failedAttempts: 2), in: store)
        #expect(store.telemetryHealth == .delayed(failedAttempts: 2))
        #expect(store.menuBarPresentation == presentation)
        #expect(store.latest == snapshot)
        #expect(store.resolvedPowerState == resolvedState)
    }

    @Test
    @MainActor
    func processSamplingIsPausedInBackgroundAndResetAcrossVisibilityChanges() async {
        let snapshot = makeTelemetrySnapshot()
        let sampler = CountingEnergySampler()
        let store = PowerLensStore(
            telemetryReader: CountingTelemetryReader(snapshot: snapshot), historyStore: StubHistoryStore(),
            energySampler: sampler, startsAutomatically: false
        )
        await store.refreshOnce(persistImmediately: false)
        #expect(await sampler.sampleCount == 0)
        store.setRefreshCadence(.interactive)
        await store.refreshOnce(persistImmediately: false)
        await waitForEnergyApps(in: store)
        #expect(await sampler.sampleCount == 1)
        #expect(!store.topEnergyApps.isEmpty)
        store.setRefreshCadence(.background)
        #expect(store.topEnergyApps.isEmpty)
        await store.refreshOnce(persistImmediately: false)
        #expect(await sampler.sampleCount == 1)
        store.setRefreshCadence(.interactive)
        await store.refreshOnce(persistImmediately: false)
        await waitForEnergyApps(in: store)
        #expect(await sampler.sampleCount == 2)
        #expect(await sampler.resetCount == 3)
    }

    @Test
    @MainActor
    func slowEnergySamplingDoesNotDelayTelemetryOrSourceIconAndCannotPublishAfterHiding() async {
        let snapshot = makeTelemetrySnapshot()
        let battery = makeTelemetrySnapshot(
            timestamp: snapshot.timestamp.addingTimeInterval(1),
            powerSource: .battery, externalConnected: false
        )
        let gate = HistoryAppendGate()
        var arrivals = gate.arrivals.makeAsyncIterator()
        let sampler = CountingEnergySampler(gate: gate)
        let store = PowerLensStore(
            telemetryReader: SequenceTelemetryReader(snapshots: [snapshot, battery]), historyStore: StubHistoryStore(),
            energySampler: sampler, startsAutomatically: false
        )
        store.setRefreshCadence(.interactive)
        let refresh = Task { await store.refreshOnce(persistImmediately: false) }
        _ = await arrivals.next()
        #expect(store.latest == snapshot)
        #expect(store.menuBarPresentation.snapshot == snapshot)
        store.setRefreshCadence(.background)
        store.receivePowerSourceObservation(
            .init(externalConnected: false, observedAt: battery.timestamp), reason: .powerSourceChanged
        )
        #expect(store.menuBarBatteryBadge == .none)
        await waitForSnapshot(battery, in: store)
        #expect(store.latest == battery)
        #expect(await sampler.sampleCount == 1)
        await gate.finish()
        await refresh.value
        #expect(store.topEnergyApps.isEmpty)
        #expect(store.latest == battery)
    }

    @Test
    @MainActor
    func blockedEnergyScanDoesNotBlockManualReadsOrStartOverlappingScans() async {
        let snapshot = makeTelemetrySnapshot()
        let gate = HistoryAppendGate()
        var arrivals = gate.arrivals.makeAsyncIterator()
        let sampler = CountingEnergySampler(gate: gate)
        let reader = CountingTelemetryReader(snapshot: snapshot)
        let store = PowerLensStore(
            telemetryReader: reader, historyStore: StubHistoryStore(),
            energySampler: sampler, startsAutomatically: false
        )
        store.setRefreshCadence(.interactive)
        let initial = Task { await store.refreshOnce(persistImmediately: false) }
        _ = await arrivals.next()

        for expectedReads in 2...4 {
            store.refreshNow()
            await waitForReadCount(expectedReads, in: reader)
            #expect(await reader.readCount() == expectedReads)
        }
        #expect(await sampler.sampleCount == 1)
        #expect(store.topEnergyApps.isEmpty)

        await gate.finish()
        await initial.value
        await waitForEnergyApps(in: store)
        #expect(!store.topEnergyApps.isEmpty)
    }

    @Test
    @MainActor
    func wakeDiscardsAnOldEnergyScanBeforePublishingTheNextScan() async {
        let snapshot = makeTelemetrySnapshot()
        let gate = HistoryAppendGate()
        var arrivals = gate.arrivals.makeAsyncIterator()
        let sampler = CountingEnergySampler(gate: gate)
        let reader = CountingTelemetryReader(snapshot: snapshot)
        let store = PowerLensStore(
            telemetryReader: reader, historyStore: StubHistoryStore(),
            energySampler: sampler, startsAutomatically: false
        )
        var publishedImpacts: [Double] = []
        let subscription = store.$topEnergyApps.sink { apps in
            publishedImpacts += apps.map(\.energyImpact)
        }
        store.setRefreshCadence(.interactive)
        let initial = Task { await store.refreshOnce(persistImmediately: false) }
        _ = await arrivals.next()
        store.receivePowerSourceObservation(
            .init(externalConnected: true, observedAt: snapshot.timestamp), reason: .wake
        )
        await waitForReadCount(2, in: reader)
        #expect(await reader.readCount() == 2)
        #expect(await sampler.sampleCount == 1)

        await gate.finish()
        await initial.value
        // Wait for the canceled scan to release its slot, then request a new
        // sample through the normal telemetry path without overlapping scans.
        for _ in 0..<200 {
            await store.refreshOnce(persistImmediately: false)
            if await sampler.sampleCount >= 2 { break }
            await Task.yield()
        }
        await waitForEnergyApps(in: store)
        #expect(await sampler.sampleCount == 2)
        #expect(publishedImpacts == [2])
        withExtendedLifetime(subscription) {}
    }

    @Test
    @MainActor
    func startupReadsOnlyTheLatestTimestampAndRetainsMinutePersistenceCadence() async {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let first = makeTelemetrySnapshot(timestamp: start)
        let second = makeTelemetrySnapshot(timestamp: start.addingTimeInterval(30))
        let third = makeTelemetrySnapshot(timestamp: start.addingTimeInterval(60))
        let reader = SequenceTelemetryReader(snapshots: [first, second, third])
        let history = StubHistoryStore(loadedSnapshots: [first])
        let store = PowerLensStore(
            telemetryReader: reader, historyStore: history, energySampler: EmptyEnergySampler(),
            startsAutomatically: true, interactiveRefreshInterval: .seconds(60),
            backgroundRefreshInterval: .seconds(60), now: { start }
        )
        await waitForSnapshot(first, in: store)
        await store.refreshOnce(persistImmediately: false)
        await store.refreshOnce(persistImmediately: false)
        #expect(await history.recentLoadCount == 0)
        #expect(await history.appendedSnapshots() == [third])
    }


    @Test
    @MainActor
    func anEventDuringAppendDoesNotInheritAlreadyCommittedManualPersistence() async {
        let snapshot = makeTelemetrySnapshot()
        let gate = HistoryAppendGate()
        var appends = gate.arrivals.makeAsyncIterator()
        let history = StubHistoryStore(appendGate: gate)
        let reader = CountingTelemetryReader(snapshot: snapshot)
        let store = PowerLensStore(
            telemetryReader: reader, historyStore: history, energySampler: EmptyEnergySampler(),
            startsAutomatically: false
        )
        let manual = Task { await store.refreshOnce() }
        _ = await appends.next()
        store.receivePowerSourceObservation(
            .init(externalConnected: true, observedAt: snapshot.timestamp), reason: .wake
        )
        await gate.finish()
        await manual.value
        #expect(await reader.readCount() == 2)
        #expect(await history.appendedSnapshots() == [snapshot])
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

/// Returns the queued modes in order, then repeats the last one.
private actor StubEnergyModeReader: EnergyModeReading {
    private var modes: [EnergyMode]
    private(set) var readCount = 0

    init(_ modes: [EnergyMode]) {
        self.modes = modes
    }

    func read(lowPowerFallback: Bool) async -> EnergyMode {
        readCount += 1
        return modes.count > 1 ? modes.removeFirst() : modes.first ?? .standard
    }
}

private actor ControlledTelemetryReader: TelemetryReading {
    private var continuations: [CheckedContinuation<TelemetryReadResult, any Error>] = []
    private var startedReads = 0

    func readSnapshot(preference: TelemetryEnginePreference) async throws -> TelemetryReadResult {
        startedReads += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func readCount() -> Int { startedReads }

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

    func latestSampleTimestamp() async throws -> Date? {
        if blocksLoad {
            loadStarted = true
            loadStartWaiters.forEach { $0.resume() }
            loadStartWaiters.removeAll()
            await withCheckedContinuation { continuation in
                loadContinuation = continuation
            }
        }
        return loadedSnapshots.map(\.timestamp).max()
    }

    func loadRecent(since cutoffDate: Date) async throws -> [TelemetrySnapshot] {
        recentLoadCount += 1
        return loadedSnapshots
    }

    private(set) var recentLoadCount = 0

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
    private var isOpen = false

    init() {
        (arrivals, arrived) = AsyncStream.makeStream(of: Void.self)
    }

    func suspend() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            arrived.yield(())
        }
    }

    func finish() {
        isOpen = true
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

private func waitForControlledReadCount(_ count: Int, in reader: ControlledTelemetryReader) async {
    for _ in 0..<1_000 {
        if await reader.readCount() >= count { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
private func waitForSnapshot(_ snapshot: TelemetrySnapshot, in store: PowerLensStore) async {
    for _ in 0..<1_000 {
        if store.latest == snapshot { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
private func waitForTelemetryHealth(_ health: TelemetryHealth, in store: PowerLensStore) async {
    for _ in 0..<1_000 {
        if store.telemetryHealth == health { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
private func waitForEnergyApps(in store: PowerLensStore) async {
    for _ in 0..<1_000 {
        if !store.topEnergyApps.isEmpty { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

private actor CountingEnergySampler: ProcessEnergySampling {
    private(set) var sampleCount = 0
    private(set) var resetCount = 0
    private let gate: HistoryAppendGate?

    init(gate: HistoryAppendGate? = nil) { self.gate = gate }

    func reset() async { resetCount += 1 }

    func sample(now: Date) async -> [AppEnergyUsage] {
        sampleCount += 1
        let sampleNumber = sampleCount
        if let gate { await gate.suspend() }
        return [.init(appPath: "/Test.app", name: "Test", energyImpact: Double(sampleNumber))]
    }
}
