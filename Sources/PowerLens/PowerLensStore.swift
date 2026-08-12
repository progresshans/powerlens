import Combine
import Foundation
import OSLog

@MainActor
final class PowerLensStore: ObservableObject {
    enum RefreshCadence {
        case interactive
        case background
    }

    @Published private(set) var latest: TelemetrySnapshot?
    @Published private(set) var telemetryHealth = TelemetryHealth.waiting
    @Published private(set) var historyHealth = HistoryHealth.checking
    @Published private(set) var diagnostics: [DiagnosticItem] = []
    @Published private(set) var topEnergyApps: [AppEnergyUsage] = []
    @Published private(set) var menuBarSymbolName = "bolt.fill"
    @Published private(set) var menuBarBatteryBadge = MenuBarStatusItemRenderer.Badge.none
    @Published private(set) var history: [TelemetrySnapshot] = []
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
    private static let telemetryLogger = Logger(
        subsystem: "com.progresshans.powerlens",
        category: "Telemetry"
    )
    private static let historyLogger = Logger(
        subsystem: "com.progresshans.powerlens",
        category: "History"
    )
    private var refreshTask: Task<Void, Never>?
    private var refreshSequence = 0
    private var powerStateTracker: PowerStateTracker
    private let memoryWindow: TimeInterval = 30 * 24 * 3600
    private let purgeInterval: TimeInterval = 24 * 3600
    private var lastPurgeAt: Date?
    private let interactiveRefreshInterval: Duration = .seconds(3)
    private let backgroundRefreshInterval: Duration = .seconds(10)
    private var refreshCadence: RefreshCadence = .background

    var telemetryUnavailable: Bool {
        telemetryHealth.isUnavailable
    }

    init(
        telemetryReader: any TelemetryReading = TelemetryReadService(),
        historyStore: any HistoryStoring = HistoryStore(),
        energySampler: any ProcessEnergySampling = ProcessEnergySampler(),
        systemCompatibilityRecorder: any SystemCompatibilityRecording =
            SystemCompatibilityRecorder.shared,
        startsAutomatically: Bool = true,
        now: @escaping () -> Date = Date.init,
        powerStateConfiguration: PowerStateHysteresisConfiguration = .init()
    ) {
        self.telemetryReader = telemetryReader
        self.historyStore = historyStore
        self.energySampler = energySampler
        self.systemCompatibilityRecorder = systemCompatibilityRecorder
        self.now = now
        self.powerStateTracker = PowerStateTracker(
            configuration: powerStateConfiguration
        )

        guard startsAutomatically else {
            return
        }

        startRefreshTask()
    }

    private func startRefreshTask() {
        refreshTask = Task {
            do {
                history = try await historyStore.loadRecent(
                    since: now().addingTimeInterval(-memoryWindow)
                )
                recordHistorySuccess()
            } catch {
                recordHistoryFailure(error, operation: "load recent history")
            }
            await purgeIfNeeded()
            await refresh(persistImmediately: history.isEmpty)
            await refreshLoop()
        }
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
        } catch {
            recordHistoryFailure(error, operation: "purge history")
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    func refreshNow() {
        Task {
            await refresh(persistImmediately: true)
        }
    }

    func refreshOnce(persistImmediately: Bool = true) async {
        await refresh(persistImmediately: persistImmediately)
    }

    func setRefreshCadence(_ cadence: RefreshCadence) {
        refreshCadence = cadence
    }

    func historyRetentionPreferencesChanged() {
        lastPurgeAt = nil
        Task {
            await purgeIfNeeded()
        }
    }

    func history(hours: Double) -> [TelemetrySnapshot] {
        let cutoff = now().addingTimeInterval(-(hours * 3600))
        return history.filter { $0.timestamp >= cutoff }
    }

    /// Loads aggregated series, summary statistics, and the long-term battery
    /// health trend for the Insights view. The health trend ignores the range
    /// because capacity changes slowly and is most useful over the full record.
    func loadInsights(for range: HistoryRange) async -> InsightsData {
        let currentDate = now()
        let interval = range.interval(now: currentDate)

        // Full-detail samples exist only within the raw retention window; older
        // data is read from the downsampled rollups so long ranges still cover
        // the full record at a coarser resolution.
        let rawCutoff = RawHistoryWindow.current.seconds
            .map { currentDate.addingTimeInterval(-$0) }
            ?? Date(timeIntervalSince1970: 0)
        let rawStart = max(interval.start, rawCutoff)

        do {
            var rawSeries: [AggregatedTelemetryPoint] = []
            if rawStart < interval.end {
                rawSeries = try await historyStore.aggregatedSeries(
                    for: DateInterval(start: rawStart, end: interval.end),
                    bucketSeconds: range.bucketSeconds
                )
            }

            var rollups: [AggregatedTelemetryPoint] = []
            if interval.start < rawCutoff {
                rollups = try await historyStore.rollupSeries(
                    for: DateInterval(
                        start: interval.start,
                        end: min(rawCutoff, interval.end)
                    )
                )
            }

            let summary = try await historyStore.summary(for: interval)
            let healthTrend = try await historyStore.batteryHealthTrend(
                since: Date(timeIntervalSince1970: 0)
            )
            let mergedSeries = (rollups + rawSeries).sorted {
                $0.bucketStart < $1.bucketStart
            }
            recordHistorySuccess()

            return InsightsData(
                range: range,
                interval: interval,
                series: mergedSeries,
                summary: summary,
                healthTrend: healthTrend
            )
        } catch {
            recordHistoryFailure(error, operation: "load insights")
            return InsightsData(
                range: range,
                interval: interval,
                series: [],
                summary: .empty(range: interval),
                healthTrend: []
            )
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

    private func refreshLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: currentRefreshInterval)
            } catch {
                return
            }
            await refresh(persistImmediately: false)
            await purgeIfNeeded()
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

    private func refresh(persistImmediately: Bool) async {
        refreshSequence += 1
        let sequence = refreshSequence
        let preference = TelemetryEnginePreference.current
        requestedTelemetryEngine = preference

        let result: TelemetryReadResult
        do {
            result = try await telemetryReader.readSnapshot(
                preference: preference
            )
        } catch {
            guard sequence == refreshSequence else {
                return
            }

            lastRefreshAttemptAt = now()
            let failedAttempts = telemetryHealth.failedAttempts + 1
            telemetryHealth = latest == nil
                ? .unavailable(failedAttempts: failedAttempts)
                : .delayed(failedAttempts: failedAttempts)
            Self.telemetryLogger.warning(
                "Telemetry refresh failed; consecutive attempts: \(failedAttempts, privacy: .public); error: \(String(describing: error), privacy: .private)"
            )
            return
        }

        guard sequence == refreshSequence else {
            return
        }

        let sampledEnergyApps = await energySampler.sample(now: now())
        guard sequence == refreshSequence else {
            return
        }

        let compatibilityObservedAt = now()
        for diagnostic in result.systemCompatibilityDiagnostics {
            await systemCompatibilityRecorder.record(
                diagnostic,
                observedAt: compatibilityObservedAt
            )
        }
        guard sequence == refreshSequence else {
            return
        }

        telemetryHealth = .live
        lastRefreshAttemptAt = now()

        let snapshot = result.snapshot
        let resolvedState = powerStateTracker.resolve(snapshot)
        let resolvedDiagnostics = snapshot.diagnostics(
            resolvedState: resolvedState
        )
        menuBarSymbolName = snapshot.menuBarSymbolName(
            using: resolvedDiagnostics,
            externalPowerState: resolvedState.externalPowerState
        )
        menuBarBatteryBadge = .resolved(
            for: resolvedState.externalPowerState
        )

        // Publish the resolved interpretation before the raw snapshot. The
        // existing `$latest` subscriber is the commit signal for AppKit UI.
        resolvedPowerState = resolvedState
        latest = snapshot
        diagnostics = resolvedDiagnostics
        lastRefreshAt = snapshot.timestamp
        activeTelemetryEngine = result.activeEngine
        topEnergyApps = sampledEnergyApps
        systemCompatibilityDiagnostics =
            result.systemCompatibilityDiagnostics

        let shouldPersist = persistImmediately || shouldPersist(snapshot: snapshot)
        guard shouldPersist else {
            return
        }

        // Charging-policy observations explain the current UI only. Keeping
        // them out of history avoids silently changing Insights, CSV, or JSON
        // semantics before a dedicated history schema is designed.
        let historicalSnapshot = snapshot.withChargingPolicyStatus(nil)
        history.append(historicalSnapshot)
        let cutoff = now().addingTimeInterval(-memoryWindow)
        history.removeAll { $0.timestamp < cutoff }

        do {
            try await historyStore.append(historicalSnapshot)
            recordHistorySuccess()
        } catch {
            recordHistoryFailure(error, operation: "append history")
        }
    }

    private func shouldPersist(snapshot: TelemetrySnapshot) -> Bool {
        guard let last = history.last else {
            return true
        }

        return snapshot.timestamp.timeIntervalSince(last.timestamp) >= 60
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
