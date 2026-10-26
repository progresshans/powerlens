import Combine
import Foundation
import OSLog

@MainActor
final class PowerLensStore: ObservableObject {
    enum RefreshCadence: Equatable {
        case interactive
        case background
    }

    private enum RefreshPersistencePolicy: Int {
        case disabled
        case ifDue
        case immediately
    }

    private struct RefreshRequest {
        let sequence: Int
        let persistencePolicy: RefreshPersistencePolicy
    }

    private enum AutomaticRefreshPhase {
        case disabled
        case preparingHistory
        case initialRefresh
        case running
    }

    @Published private(set) var latest: TelemetrySnapshot?
    @Published private(set) var telemetryHealth = TelemetryHealth.waiting
    @Published private(set) var historyHealth = HistoryHealth.checking
    @Published private(set) var diagnostics: [DiagnosticItem] = []
    @Published private(set) var topEnergyApps: [AppEnergyUsage] = []
    @Published private(set) var menuBarPresentation = MenuBarPresentation.waiting
    @Published private(set) var historyRevision = 0
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var lastRefreshAttemptAt: Date?
    @Published private(set) var requestedTelemetryEngine = TelemetryEnginePreference.current
    @Published private(set) var activeTelemetryEngine: TelemetryEngineKind = .compatible
    @Published private(set) var resolvedPowerState: ResolvedPowerState?
    @Published private(set) var systemCompatibilityDiagnostics:
        [SystemCompatibilityDiagnostic] = []

    private let telemetryReader: any TelemetryReading
    private let historyStore: any HistoryStoring
    private let energySampler: any ProcessEnergySampling
    private let systemCompatibilityRecorder: any SystemCompatibilityRecording
    private let now: () -> Date
    private let powerSourceReader: @MainActor () -> PowerSourceObservation?
    private static let telemetryLogger = Logger(
        subsystem: "com.progresshans.powerlens",
        category: "Telemetry"
    )
    private static let historyLogger = Logger(
        subsystem: "com.progresshans.powerlens",
        category: "History"
    )
    private var startupTask: Task<Void, Never>?
    private var startupInteractiveRefreshTask: Task<Void, Never>?
    private var refreshLoopTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var pendingRefresh: RefreshRequest?
    private var activePersistencePolicy = RefreshPersistencePolicy.disabled
    private var sourceReconciliationTask: Task<Void, Never>?
    private var energyResetTask: Task<Void, Never>?
    private var energySamplingTask: Task<Void, Never>?
    private var energySamplingGeneration = 0
    private var powerSourceObservation: PowerSourceObservation?
    private var powerSourceGeneration = 0
    private var lastAppliedSourceGeneration: Int?
    private var automaticRefreshPhase = AutomaticRefreshPhase.disabled
    private var refreshSequence = 0
    private var powerStateTracker: PowerStateTracker
    private var lastPersistedAt: Date?
    private let purgeInterval: TimeInterval = 24 * 3600
    private var lastPurgeAt: Date?
    private let interactiveRefreshInterval: Duration
    private let backgroundRefreshInterval: Duration
    private var refreshCadence: RefreshCadence = .background

    var telemetryUnavailable: Bool {
        telemetryHealth.isUnavailable
    }

    var menuBarSymbolName: String { menuBarPresentation.symbolName }
    var menuBarBatteryBadge: MenuBarStatusItemRenderer.Badge {
        menuBarPresentation.batteryBadge
    }

    init(
        telemetryReader: any TelemetryReading = TelemetryReadService(),
        historyStore: any HistoryStoring = HistoryStore(),
        energySampler: any ProcessEnergySampling = ProcessEnergySampler(),
        systemCompatibilityRecorder: any SystemCompatibilityRecording =
            SystemCompatibilityRecorder.shared,
        startsAutomatically: Bool = true,
        interactiveRefreshInterval: Duration = .seconds(3),
        backgroundRefreshInterval: Duration = .seconds(10),
        now: @escaping () -> Date = Date.init,
        powerSourceReader: @escaping @MainActor () -> PowerSourceObservation? = { nil },
        powerStateConfiguration: PowerStateHysteresisConfiguration = .init()
    ) {
        self.telemetryReader = telemetryReader
        self.historyStore = historyStore
        self.energySampler = energySampler
        self.systemCompatibilityRecorder = systemCompatibilityRecorder
        self.interactiveRefreshInterval = interactiveRefreshInterval
        self.backgroundRefreshInterval = backgroundRefreshInterval
        self.now = now
        self.powerSourceReader = powerSourceReader
        self.powerStateTracker = PowerStateTracker(
            configuration: powerStateConfiguration
        )

        guard startsAutomatically else {
            return
        }

        startRefreshTask()
    }

    private func startRefreshTask() {
        automaticRefreshPhase = .preparingHistory
        startupTask = Task { [weak self] in
            await self?.prepareForAutomaticRefresh()
        }
    }

    private func prepareForAutomaticRefresh() async {
        do {
            lastPersistedAt = try await historyStore.latestSampleTimestamp()
            recordHistorySuccess()
            historyRevision += 1
        } catch {
            recordHistoryFailure(error, operation: "load latest history timestamp")
        }
        guard !Task.isCancelled else {
            return
        }

        await purgeIfNeeded()
        guard !Task.isCancelled else {
            return
        }

        automaticRefreshPhase = .initialRefresh
        startupInteractiveRefreshTask?.cancel()
        startupInteractiveRefreshTask = nil
        await refresh(
            persistencePolicy: lastPersistedAt == nil ? .immediately : .ifDue
        )
        guard !Task.isCancelled else {
            return
        }

        automaticRefreshPhase = .running
        restartRefreshLoop(refreshImmediately: false)
    }

    private func purgeIfNeeded() async {
        let current = now()

        if let lastPurgeAt, current.timeIntervalSince(lastPurgeAt) < purgeInterval {
            return
        }

        guard let window = RawHistoryWindow.current.seconds else {
            return  // Full-detail history kept forever: nothing to prune.
        }

        lastPurgeAt = current
        do {
            try await historyStore.purge(
                olderThan: current.addingTimeInterval(-window),
                rollupBucketSeconds: LongTermResolution.current.bucketSeconds
            )
            recordHistorySuccess()
            historyRevision += 1
        } catch {
            recordHistoryFailure(error, operation: "purge history")
        }
    }

    deinit {
        startupTask?.cancel()
        startupInteractiveRefreshTask?.cancel()
        refreshLoopTask?.cancel()
        refreshTask?.cancel()
        sourceReconciliationTask?.cancel()
        energyResetTask?.cancel()
        energySamplingTask?.cancel()
    }

    func refreshNow() {
        _ = enqueueRefresh(persistencePolicy: .immediately)
    }

    func refreshOnce(persistImmediately: Bool = true) async {
        await refresh(
            persistencePolicy: persistImmediately ? .immediately : .ifDue
        )
    }

    func setRefreshCadence(_ cadence: RefreshCadence) {
        guard refreshCadence != cadence else {
            return
        }

        refreshCadence = cadence
        resetEnergySampling()
        switch automaticRefreshPhase {
        case .preparingHistory:
            if cadence == .interactive {
                restartStartupInteractiveRefresh()
            }
        case .running:
            restartRefreshLoop(refreshImmediately: cadence == .interactive)
        case .disabled, .initialRefresh:
            break
        }
    }

    func receivePowerSourceObservation(
        _ observation: PowerSourceObservation,
        reason: PowerSourceObservationReason
    ) {
        let previousSource = powerSourceObservation?.externalConnected
            ?? latest?.externalConnected
        let sourceChanged = previousSource != observation.externalConnected
        powerSourceObservation = observation
        guard sourceChanged || reason == .wake else {
            return
        }

        powerSourceGeneration += 1
        powerStateTracker.reset()
        resetEnergySampling()
        if sourceChanged {
            if let latest, latest.externalConnected != observation.externalConnected {
                // The cached sample is stale before a new read starts, but
                // observing a source change is not a failed refresh attempt.
                telemetryHealth = .delayed(failedAttempts: telemetryHealth.failedAttempts)
            }
            publishPowerSource(observation)
        }

        let generation = powerSourceGeneration
        sourceReconciliationTask?.cancel()
        let refresh = enqueueRefresh(persistencePolicy: .ifDue)
        sourceReconciliationTask = Task { [weak self] in
            await refresh.value
            guard !Task.isCancelled,
                  let self,
                  self.powerSourceGeneration == generation,
                  self.lastAppliedSourceGeneration != generation else {
                return
            }

            // The registry can briefly lag the source notification. Retry once
            // without turning a connection change into a fast polling loop.
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard self.powerSourceGeneration == generation else { return }
            await self.refresh(persistencePolicy: .ifDue)
        }
    }

    private func publishPowerSource(_ observation: PowerSourceObservation) {
        let state: ExternalPowerState = observation.externalConnected
            ? .connected : .onBattery
        menuBarPresentation = MenuBarPresentation(
            snapshot: latest,
            symbolName: state.menuBarSymbolName,
            batteryBadge: .resolved(for: state),
            statusHeadline: L10n.text(
                observation.externalConnected
                    ? "status.externalPowerConnected" : "status.runningOnBattery"
            ),
            lowPowerMode: latest?.lowPowerModeEnabled ?? false
        )
    }

    func refreshMenuBarLocalization() {
        if let powerSourceObservation,
           latest?.externalConnected != powerSourceObservation.externalConnected {
            publishPowerSource(powerSourceObservation)
        } else if let latest {
            menuBarPresentation = MenuBarPresentation(
                snapshot: latest,
                symbolName: menuBarSymbolName,
                batteryBadge: menuBarBatteryBadge,
                statusHeadline: latest.statusHeadline(resolvedState: resolvedPowerState),
                lowPowerMode: menuBarPresentation.lowPowerMode,
                powerWarning: menuBarPresentation.powerWarning
            )
        }
    }

    private func resetEnergySampling() {
        energySamplingGeneration += 1
        energySamplingTask?.cancel()
        if !topEnergyApps.isEmpty {
            topEnergyApps = []
        }
        let previousReset = energyResetTask
        let sampler = energySampler
        energyResetTask = Task {
            await previousReset?.value
            await sampler.reset()
        }
    }

    private func scheduleEnergySamplingIfVisible() {
        guard refreshCadence == .interactive, energySamplingTask == nil else { return }
        let generation = energySamplingGeneration
        let reset = energyResetTask
        let sampler = energySampler
        let clock = now
        // Keep one scan in flight without holding the serialized telemetry slot.
        // Cancellation invalidates its result even if the sampler cannot stop.
        energySamplingTask = Task { [weak self] in
            defer { self?.energySamplingTask = nil }
            await reset?.value
            guard !Task.isCancelled,
                  self?.energySamplingGeneration == generation,
                  self?.refreshCadence == .interactive else { return }
            let apps = await sampler.sample(now: clock())
            guard !Task.isCancelled, let self,
                  self.energySamplingGeneration == generation,
                  self.refreshCadence == .interactive else { return }
            if self.topEnergyApps != apps {
                self.topEnergyApps = apps
            }
        }
    }

    func historyRetentionPreferencesChanged() {
        lastPurgeAt = nil
        Task {
            await purgeIfNeeded()
        }
    }

    /// Loads aggregated series, summary statistics, and the long-term battery
    /// health trend for the Insights view. The health trend ignores the range
    /// because capacity changes slowly and is most useful over the full record.
    func loadInsights(for range: HistoryRange) async -> InsightsData {
        let currentDate = now()
        do {
            try Task.checkCancellation()
            let data = try await historyStore.loadInsights(for: range, now: currentDate)
            try Task.checkCancellation()
            recordHistorySuccess()
            return data
        } catch {
            if !Task.isCancelled, !(error is CancellationError) {
                recordHistoryFailure(error, operation: "load insights")
            }
            return .empty(range: range, now: currentDate)
        }
    }

    /// Loads raw snapshots within a range for export. Bounded by the on-disk
    /// retention window.
    func exportSnapshots(for range: HistoryRange) async -> [TelemetrySnapshot] {
        let interval = range.interval(now: now())
        do {
            let loaded = try await historyStore.loadRecent(
                since: interval.start
            )
            recordHistorySuccess()
            return loaded.filter { interval.contains($0.timestamp) }
        } catch {
            recordHistoryFailure(error, operation: "export history")
            return []
        }
    }

    var telemetryStatusText: String {
        switch telemetryHealth {
        case .waiting:
            return L10n.text("telemetry.status.waiting")
        case .delayed(failedAttempts: 0):
            return L10n.text("telemetry.status.sourceTransition")
        case let .delayed(failedAttempts):
            return L10n.tr(
                "telemetry.status.delayed",
                failedAttempts
            )
        case let .unavailable(failedAttempts):
            return L10n.tr(
                "telemetry.status.unavailable",
                failedAttempts
            )
        case .live:
            break
        }

        switch (requestedTelemetryEngine, activeTelemetryEngine) {
        case (.auto, .livePrecision), (.auto, .compatible):
            return L10n.tr("telemetry.status.auto", activeTelemetryEngine.displayName)
        case (.compatible, .compatible), (.livePrecision, .livePrecision):
            return L10n.tr("telemetry.status.manual", activeTelemetryEngine.displayName)
        case (.livePrecision, .compatible):
            return L10n.tr(
                "telemetry.status.fallback",
                TelemetryEnginePreference.livePrecision.displayName,
                TelemetryEngineKind.compatible.displayName
            )
        case (.compatible, .livePrecision):
            return L10n.tr(
                "telemetry.status.fallback",
                TelemetryEnginePreference.compatible.displayName,
                TelemetryEngineKind.livePrecision.displayName
            )
        }
    }

    private func restartRefreshLoop(refreshImmediately: Bool) {
        refreshLoopTask?.cancel()
        refreshLoopTask = Task { [weak self] in
            if refreshImmediately {
                await self?.refresh(persistencePolicy: .ifDue)
            }

            while !Task.isCancelled {
                guard let interval = self?.currentRefreshInterval else {
                    return
                }
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }

                await self?.refresh(persistencePolicy: .ifDue)
                guard !Task.isCancelled else {
                    return
                }
                await self?.purgeIfNeeded()
            }
        }
    }

    private func restartStartupInteractiveRefresh() {
        startupInteractiveRefreshTask?.cancel()
        startupInteractiveRefreshTask = Task { [weak self] in
            await self?.refresh(persistencePolicy: .disabled)
        }
    }

    private var currentRefreshInterval: Duration {
        switch refreshCadence {
        case .interactive:
            interactiveRefreshInterval
        case .background:
            backgroundRefreshInterval
        }
    }

    private func refresh(
        persistencePolicy: RefreshPersistencePolicy
    ) async {
        await enqueueRefresh(persistencePolicy: persistencePolicy).value
    }

    private func enqueueRefresh(
        persistencePolicy: RefreshPersistencePolicy
    ) -> Task<Void, Never> {
        // Every entry point, including manual refreshes, must leave persistence
        // to startup until the initial history load has finished.
        let effectivePersistencePolicy: RefreshPersistencePolicy =
            automaticRefreshPhase == .preparingHistory ? .disabled : persistencePolicy
        refreshSequence += 1
        let sequence = refreshSequence

        if let refreshTask {
            // Preserve manual persistence when a newer request supersedes the
            // current read. Any number of events share one follow-up read.
            let policy = max(
                effectivePersistencePolicy.rawValue,
                pendingRefresh?.persistencePolicy.rawValue ?? 0,
                activePersistencePolicy.rawValue
            )
            pendingRefresh = RefreshRequest(
                sequence: sequence,
                persistencePolicy: RefreshPersistencePolicy(rawValue: policy)!
            )
            return refreshTask
        }

        let request = RefreshRequest(
            sequence: sequence,
            persistencePolicy: effectivePersistencePolicy
        )
        activePersistencePolicy = effectivePersistencePolicy
        let task = Task { [weak self] in
            guard let self else { return }
            var request = request
            repeat {
                self.activePersistencePolicy = request.persistencePolicy
                await self.performRefresh(request)
                guard let pending = self.pendingRefresh else { break }
                self.pendingRefresh = nil
                request = pending
            } while !Task.isCancelled
            self.activePersistencePolicy = .disabled
            self.pendingRefresh = nil
            self.refreshTask = nil
        }
        refreshTask = task
        return task
    }

    private func performRefresh(_ request: RefreshRequest) async {
        let sequence = request.sequence
        guard sequence == refreshSequence else { return }
        let sourceGeneration = powerSourceGeneration
        let preference = TelemetryEnginePreference.current
        requestedTelemetryEngine = preference

        let result: TelemetryReadResult
        do {
            result = try await telemetryReader.readSnapshot(
                preference: preference
            )
        } catch {
            guard sequence == refreshSequence,
                  sourceGeneration == powerSourceGeneration else {
                return
            }

            recordTelemetryFailure()
            Self.telemetryLogger.warning(
                "Telemetry refresh failed; consecutive attempts: \(self.telemetryHealth.failedAttempts, privacy: .public); error: \(String(describing: error), privacy: .private)"
            )
            return
        }

        guard sequence == refreshSequence,
              sourceGeneration == powerSourceGeneration else {
            return
        }

        let snapshot = result.snapshot
        if let observation = powerSourceObservation,
           observation.externalConnected != snapshot.externalConnected {
            // Reconfirm through IOPS so polling also recovers from a missed
            // notification. Never rewrite a raw sensor snapshot to match it.
            if let current = powerSourceReader() {
                powerSourceObservation = current
                if current.externalConnected != observation.externalConnected {
                    powerSourceGeneration += 1
                    powerStateTracker.reset()
                    resetEnergySampling()
                    publishPowerSource(current)
                }
            }
            guard powerSourceObservation?.externalConnected == snapshot.externalConnected else {
                recordTelemetryFailure()
                return
            }
        }

        telemetryHealth = .live
        lastRefreshAttemptAt = now()

        let resolvedState = powerStateTracker.resolve(snapshot)
        let resolvedDiagnostics = snapshot.diagnostics(
            resolvedState: resolvedState
        )
        resolvedPowerState = resolvedState
        latest = snapshot
        diagnostics = resolvedDiagnostics
        lastRefreshAt = snapshot.timestamp
        activeTelemetryEngine = result.activeEngine
        systemCompatibilityDiagnostics =
            result.systemCompatibilityDiagnostics
        lastAppliedSourceGeneration = powerSourceGeneration
        menuBarPresentation = MenuBarPresentation(
            snapshot: snapshot,
            symbolName: snapshot.menuBarSymbolName(
                using: resolvedDiagnostics,
                externalPowerState: resolvedState.externalPowerState
            ),
            batteryBadge: .resolved(for: resolvedState.externalPowerState),
            statusHeadline: snapshot.statusHeadline(resolvedState: resolvedState),
            lowPowerMode: snapshot.lowPowerModeEnabled,
            powerWarning: resolvedState.powerDeliveryState == .sustainedShortfall
        )

        let shouldWriteHistory: Bool
        switch request.persistencePolicy {
        case .ifDue:
            shouldWriteHistory = shouldPersist(snapshot: snapshot)
        case .immediately:
            shouldWriteHistory = true
        case .disabled:
            shouldWriteHistory = false
        }
        activePersistencePolicy = .disabled
        if shouldWriteHistory {
            // Charging policy remains a live explanation only. Raw electrical
            // readings retain their original values and observation time.
            let historicalSnapshot = snapshot.withChargingPolicyStatus(nil)
            do {
                try await historyStore.append(historicalSnapshot)
                lastPersistedAt = snapshot.timestamp
                recordHistorySuccess()
                historyRevision += 1
            } catch {
                recordHistoryFailure(error, operation: "append history")
            }
        }

        let compatibilityObservedAt = now()
        for diagnostic in result.systemCompatibilityDiagnostics {
            await systemCompatibilityRecorder.record(
                diagnostic,
                observedAt: compatibilityObservedAt
            )
        }
        if sequence == refreshSequence {
            scheduleEnergySamplingIfVisible()
        }
    }

    /// The last hour of saved history for the Dashboard chart. History is
    /// written once a minute, so callers reload when `historyRevision` changes.
    func recentPowerHistory() async -> [RecentPowerSample] {
        let cutoff = now().addingTimeInterval(-RecentPowerSample.window)
        do {
            return try await historyStore.loadRecent(since: cutoff).map(RecentPowerSample.init(snapshot:))
        } catch {
            recordHistoryFailure(error, operation: "load recent power")
            return []
        }
    }

    private func recordTelemetryFailure() {
        lastRefreshAttemptAt = now()
        let failedAttempts = telemetryHealth.failedAttempts + 1
        telemetryHealth = latest == nil
            ? .unavailable(failedAttempts: failedAttempts)
            : .delayed(failedAttempts: failedAttempts)
    }

    private func shouldPersist(snapshot: TelemetrySnapshot) -> Bool {
        guard let lastPersistedAt else {
            return true
        }

        return snapshot.timestamp.timeIntervalSince(lastPersistedAt) >= 60
    }

    private func recordHistorySuccess() {
        historyHealth = .available
    }

    private func recordHistoryFailure(
        _ error: any Error,
        operation: String
    ) {
        historyHealth = .degraded
        Self.historyLogger.error(
            "History operation failed: \(operation, privacy: .public); error: \(String(describing: error), privacy: .private)"
        )
    }
}
