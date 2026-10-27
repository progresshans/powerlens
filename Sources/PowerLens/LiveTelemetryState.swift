import Foundation

/// One publication contains a sample, its interpretation, and the current
/// source observation. A source change never rewrites the cached sensor data.
@MainActor
struct LiveTelemetryState {
    private(set) var snapshot: TelemetrySnapshot?
    private(set) var health: TelemetryHealth = .waiting
    private(set) var source: PowerSourceObservation?
    private(set) var resolvedState: ResolvedPowerState?
    private(set) var diagnostics: [DiagnosticItem] = []
    private(set) var activeEngine: TelemetryEngineKind = .compatible
    private(set) var compatibilityDiagnostics: [SystemCompatibilityDiagnostic] = []
    private(set) var lastAttemptAt: Date?
    private(set) var presentation: LivePowerPresentation?
    private(set) var menuBar = MenuBarPresentation.waiting

    var isAwaitingSource: Bool {
        guard let source, let snapshot else { return false }
        return source.externalConnected != snapshot.externalConnected
    }

    mutating func observe(_ observation: PowerSourceObservation) {
        source = observation
        if isAwaitingSource {
            health = .delayed(failedAttempts: health.failedAttempts)
        }
        rebuildPresentation()
    }

    mutating func accept(_ result: TelemetryReadResult, resolvedState: ResolvedPowerState, attemptedAt: Date) {
        snapshot = result.snapshot
        self.resolvedState = resolvedState
        activeEngine = result.activeEngine
        compatibilityDiagnostics = result.systemCompatibilityDiagnostics
        lastAttemptAt = attemptedAt
        health = .live
        rebuildPresentation()
    }

    mutating func fail(at date: Date) {
        lastAttemptAt = date
        let attempts = health.failedAttempts + 1
        health = snapshot == nil ? .unavailable(failedAttempts: attempts) : .delayed(failedAttempts: attempts)
        // Source reconciliation remains pending independently of this count.
    }

    mutating func rebuildPresentation() {
        diagnostics = snapshot?.diagnostics(resolvedState: resolvedState) ?? []
        presentation = snapshot.map {
            LivePowerPresentation(snapshot: $0, resolvedState: resolvedState,
                                  diagnostics: diagnostics, isAwaitingSource: isAwaitingSource)
        }
        if let source, snapshot?.externalConnected != source.externalConnected {
            let state: ExternalPowerState = source.externalConnected ? .connected : .onBattery
            menuBar = MenuBarPresentation(
                snapshot: snapshot, symbolName: state.menuBarSymbolName,
                batteryBadge: .resolved(for: state),
                statusHeadline: L10n.text(source.externalConnected ? "status.externalPowerConnected" : "status.runningOnBattery"),
                lowPowerMode: snapshot?.lowPowerModeEnabled ?? false
            )
        } else if let snapshot, let resolvedState {
            menuBar = MenuBarPresentation(
                snapshot: snapshot,
                symbolName: snapshot.menuBarSymbolName(using: diagnostics, externalPowerState: resolvedState.externalPowerState),
                batteryBadge: .resolved(for: resolvedState.externalPowerState),
                statusHeadline: snapshot.statusHeadline(resolvedState: resolvedState),
                lowPowerMode: snapshot.lowPowerModeEnabled,
                powerWarning: resolvedState.powerDeliveryState == .sustainedShortfall
            )
        }
    }
}

/// Shared by every live surface. Presentation calculations run once per
/// accepted sample/source event or localization change, not once per card.
struct LivePowerPresentation {
    let isAwaitingSource: Bool
    let status: PowerStatusPresentation
    let readings: PowerFlowReadings
    let graph: PowerFlowGraph
    let tooltip: String
    let battery: MetricTilePresentation
    let health: MetricTilePresentation
    let temperature: MetricTilePresentation
    let charger: ChargerUsagePresentation
    let notice: PowerNotice?
    let diagnostics: [DiagnosticItem]

    init(snapshot: TelemetrySnapshot, resolvedState: ResolvedPowerState?,
         diagnostics: [DiagnosticItem], isAwaitingSource: Bool) {
        self.isAwaitingSource = isAwaitingSource
        let readings = PowerFlowReadings(snapshot: snapshot)
        self.readings = readings
        tooltip = PowerFlowTooltip.text(snapshot: snapshot, readings: readings)
        graph = PowerFlowGraph(model: PowerFlowPresentationModel(snapshot: snapshot, readings: readings))
        status = isAwaitingSource ? .sourceTransition
            : PowerStatusPresentation(snapshot: snapshot, resolvedState: resolvedState, readings: readings)
        battery = .battery(snapshot: snapshot, resolvedState: resolvedState)
        health = .health(snapshot: snapshot)
        temperature = .temperature(snapshot: snapshot)
        charger = ChargerUsagePresentation(snapshot: snapshot, readings: readings)
        self.diagnostics = isAwaitingSource ? []
            : snapshot.diagnosticsExcludingPrimaryStatus(diagnostics, resolvedState: resolvedState)
        notice = isAwaitingSource ? nil
            : PowerNotice.current(snapshot: snapshot, resolvedState: resolvedState, diagnostics: self.diagnostics)
    }
}
