import Foundation

@MainActor
final class PowerLensStore: ObservableObject {
    enum RefreshCadence {
        case interactive
        case background
    }

    @Published private(set) var latest: TelemetrySnapshot?
    @Published private(set) var diagnostics: [DiagnosticItem] = []
    @Published private(set) var menuBarSymbolName = "bolt.fill"
    @Published private(set) var menuBarBatteryBadge = MenuBarStatusItemRenderer.Badge.none
    @Published private(set) var history: [TelemetrySnapshot] = []
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var requestedTelemetryEngine = TelemetryEnginePreference.current
    @Published private(set) var activeTelemetryEngine: TelemetryEngineKind = .compatible

    private let telemetryReader: any TelemetryReading
    private let historyStore: any HistoryStoring
    private let now: () -> Date
    private var refreshTask: Task<Void, Never>?
    private var refreshSequence = 0
    private var recentSnapshots: [TelemetrySnapshot] = []
    private let memoryWindow: TimeInterval = 30 * 24 * 3600
    private let interactiveRefreshInterval: Duration = .seconds(3)
    private let backgroundRefreshInterval: Duration = .seconds(10)
    private let diagnosticStabilitySamples = 3
    private let holdStateStabilitySamples = 5
    private var refreshCadence: RefreshCadence = .background

    init(
        telemetryReader: any TelemetryReading = TelemetryReadService(),
        historyStore: any HistoryStoring = HistoryStore(),
        startsAutomatically: Bool = true,
        now: @escaping () -> Date = Date.init
    ) {
        self.telemetryReader = telemetryReader
        self.historyStore = historyStore
        self.now = now

        guard startsAutomatically else {
            return
        }

        startRefreshTask()
    }

    private func startRefreshTask() {
        refreshTask = Task {
            history = await historyStore.loadRecent(since: now().addingTimeInterval(-memoryWindow))
            await refresh(persistImmediately: history.isEmpty)
            await refreshLoop()
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

    func history(hours: Double) -> [TelemetrySnapshot] {
        let cutoff = Date().addingTimeInterval(-(hours * 3600))
        return history.filter { $0.timestamp >= cutoff }
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
            return
        }

        guard sequence == refreshSequence else {
            return
        }

        let snapshot = result.snapshot
        recentSnapshots.append(snapshot)
        recentSnapshots = Array(recentSnapshots.suffix(max(diagnosticStabilitySamples, holdStateStabilitySamples)))
        let stableDiagnostics = TelemetrySnapshot.stableDiagnostics(
            for: recentSnapshots,
            requiredConsecutiveSamples: diagnosticStabilitySamples
        )
        let stableExternalPowerState = TelemetrySnapshot.stableExternalPowerState(
            for: recentSnapshots,
            requiredConsecutiveSamples: holdStateStabilitySamples
        )
        menuBarSymbolName = snapshot.menuBarSymbolName(
            using: stableDiagnostics,
            externalPowerState: stableExternalPowerState
        )
        menuBarBatteryBadge = .resolved(for: stableExternalPowerState)

        latest = snapshot
        diagnostics = stableDiagnostics
        lastRefreshAt = snapshot.timestamp
        activeTelemetryEngine = result.activeEngine

        let shouldPersist = persistImmediately || shouldPersist(snapshot: snapshot)
        guard shouldPersist else {
            return
        }

        history.append(snapshot)
        let cutoff = now().addingTimeInterval(-memoryWindow)
        history.removeAll { $0.timestamp < cutoff }

        await historyStore.append(snapshot)
    }

    private func shouldPersist(snapshot: TelemetrySnapshot) -> Bool {
        guard let last = history.last else {
            return true
        }

        return snapshot.timestamp.timeIntervalSince(last.timestamp) >= 60
    }
}
