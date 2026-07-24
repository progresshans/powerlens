import Combine
import Foundation

@MainActor
final class PowerLensStore: ObservableObject {
    enum RefreshCadence {
        case interactive
        case background
    }

    @Published private(set) var latest: TelemetrySnapshot?
    @Published private(set) var telemetryUnavailable = false
    @Published private(set) var diagnostics: [DiagnosticItem] = []
    @Published private(set) var topEnergyApps: [AppEnergyUsage] = []
    @Published private(set) var menuBarSymbolName = "bolt.fill"
    @Published private(set) var menuBarBatteryBadge = MenuBarStatusItemRenderer.Badge.none
    @Published private(set) var history: [TelemetrySnapshot] = []
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var requestedTelemetryEngine = TelemetryEnginePreference.current
    @Published private(set) var activeTelemetryEngine: TelemetryEngineKind = .compatible
    @Published private(set) var resolvedPowerState: ResolvedPowerState?

    private let telemetryReader: any TelemetryReading
    private let historyStore: any HistoryStoring
    private let now: () -> Date
    private let energySampler = ProcessEnergySampler()
    private var refreshTask: Task<Void, Never>?
    private var refreshSequence = 0
    private var powerStateTracker: PowerStateTracker
    private let memoryWindow: TimeInterval = 30 * 24 * 3600
    private let purgeInterval: TimeInterval = 24 * 3600
    private var lastPurgeAt: Date?
    private let interactiveRefreshInterval: Duration = .seconds(3)
    private let backgroundRefreshInterval: Duration = .seconds(10)
    private var refreshCadence: RefreshCadence = .background

    init(
        telemetryReader: any TelemetryReading = TelemetryReadService(),
        historyStore: any HistoryStoring = HistoryStore(),
        startsAutomatically: Bool = true,
        now: @escaping () -> Date = Date.init,
        powerStateConfiguration: PowerStateHysteresisConfiguration = .init()
    ) {
        self.telemetryReader = telemetryReader
        self.historyStore = historyStore
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
            history = await historyStore.loadRecent(since: now().addingTimeInterval(-memoryWindow))
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

        lastPurgeAt = current

        guard let window = RawHistoryWindow.current.seconds else {
            return  // Full-detail history kept forever: nothing to prune.
        }

        await historyStore.purge(
            olderThan: current.addingTimeInterval(-window),
            rollupBucketSeconds: LongTermResolution.current.bucketSeconds
        )
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

    func history(hours: Double) -> [TelemetrySnapshot] {
        let cutoff = Date().addingTimeInterval(-(hours * 3600))
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

        var rawSeries: [AggregatedTelemetryPoint] = []
        if rawStart < interval.end {
            rawSeries = await historyStore.aggregatedSeries(
                for: DateInterval(start: rawStart, end: interval.end),
                bucketSeconds: range.bucketSeconds
            )
        }

        var rollups: [AggregatedTelemetryPoint] = []
        if interval.start < rawCutoff {
            rollups = await historyStore.rollupSeries(
                for: DateInterval(start: interval.start, end: min(rawCutoff, interval.end))
            )
        }

        let summary = await historyStore.summary(for: interval)
        let healthTrend = await historyStore.batteryHealthTrend(since: Date(timeIntervalSince1970: 0))
        let mergedSeries = (rollups + rawSeries).sorted { $0.bucketStart < $1.bucketStart }

        return InsightsData(
            range: range,
            interval: interval,
            series: mergedSeries,
            summary: summary,
            healthTrend: healthTrend
        )
    }

    /// Loads raw snapshots within a range for export. Bounded by the on-disk
    /// retention window.
    func exportSnapshots(for range: HistoryRange) async -> [TelemetrySnapshot] {
        let interval = range.interval(now: now())
        let loaded = await historyStore.loadRecent(since: interval.start)
        return loaded.filter { interval.contains($0.timestamp) }
    }

    var telemetryStatusText: String {
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
            try? await Task.sleep(for: currentRefreshInterval)
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

        guard let result = try? await telemetryReader.readSnapshot(preference: preference) else {
            if latest == nil {
                telemetryUnavailable = true
            }
            return
        }

        guard sequence == refreshSequence else {
            return
        }

        telemetryUnavailable = false

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
        topEnergyApps = energySampler.sample(now: now())

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

        await historyStore.append(historicalSnapshot)
    }

    private func shouldPersist(snapshot: TelemetrySnapshot) -> Bool {
        guard let last = history.last else {
            return true
        }

        return snapshot.timestamp.timeIntervalSince(last.timestamp) >= 60
    }
}
