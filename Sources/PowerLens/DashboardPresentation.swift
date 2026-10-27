import Foundation

/// The Now page's charger card: how much of the adapter's rating is in use.
/// An unknown input or rating is said plainly, never read as spare capacity.
struct ChargerUsagePresentation: Equatable {
    let value: String
    let unit: String?
    let caption: String
    /// Share of the rating in use, or nil when unknown.
    let fraction: Double?

    init(snapshot: TelemetrySnapshot, readings: PowerFlowReadings, resolvedState: ResolvedPowerState? = nil) {
        guard snapshot.externalConnected else {
            value = L10n.text("common.none")
            unit = nil
            caption = L10n.text("charger.usage.disconnected")
            fraction = nil
            return
        }

        let input = readings.inputPower?.watts
        let rated = snapshot.adapterMaxPowerW.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        value = input.map(Formatters.power) ?? L10n.text("common.none")
        unit = rated.map { "/ \(Formatters.ratedPower($0))" }

        guard let rated else {
            caption = L10n.text("charger.usage.unknownRating")
            fraction = nil
            return
        }
        guard let input else {
            caption = L10n.text("charger.usage.unknown")
            fraction = nil
            return
        }

        let used = input / rated
        fraction = used
        if resolvedState?.powerDeliveryState == .sustainedShortfall {
            caption = L10n.text("charger.usage.shortfall")
            return
        }
        caption = switch used {
        case ..<0.35: L10n.text("charger.usage.light")
        case ..<0.7: L10n.text("charger.usage.half")
        case ..<0.9: L10n.text("charger.usage.high")
        default: L10n.text("charger.usage.full")
        }
    }
}

/// Gauge fills for Dashboard cards. Each is nil when its reading is unknown,
/// so a missing value never draws as an empty or assumed bar.
enum DashboardGauge {
    static func batteryLevel(_ snapshot: TelemetrySnapshot) -> Double? {
        snapshot.batteryLevel.map { $0 / 100 }
    }

    static func capacity(_ snapshot: TelemetrySnapshot) -> Double? {
        snapshot.chargeHealthPercent.map { $0 / 100 }
    }

    /// Cycles used against the design count; unknown when either is missing.
    static func cycles(_ snapshot: TelemetrySnapshot) -> Double? {
        guard let count = snapshot.cycleCount, let design = snapshot.designCycleCount, design > 0 else {
            return nil
        }
        return Double(count) / Double(design)
    }
}

enum DashboardInsight {
    /// "Temperature is fine" only when macOS reports a thermal state.
    static func temperatureTitle(snapshot: TelemetrySnapshot) -> String {
        guard L10n.isKnownThermalState(snapshot.thermalState) else {
            return L10n.text("insight.temperature.unknown")
        }
        return L10n.tr("insight.temperature", MetricTilePresentation.temperature(snapshot: snapshot).caption)
    }
}

/// The Battery page's charging method card, read from the configured macOS
/// charging policy. The policy is read on every refresh, on battery too, so a
/// limit stays visible after unplugging; an unreadable policy is unknown, never
/// the macOS default.
struct ChargingMethodPresentation: Equatable {
    let value: String
    let caption: String
    /// How full the battery is allowed to charge, or nil when unknown.
    let fraction: Double?

    init(policy: ObservedChargingPolicyStatus?) {
        switch policy {
        case .inactive:
            value = L10n.text("battery.charging.default")
            caption = L10n.text("battery.charging.defaultCaption")
            fraction = 1
        case let .manualLimit(target) where (1...100).contains(target):
            value = Formatters.percent(Double(target))
            caption = L10n.tr("battery.charging.limitCaption", Formatters.percent(Double(target)))
            fraction = Double(target) / 100
        case .optimizedCharging:
            value = L10n.text("battery.charging.optimized")
            caption = L10n.text("battery.charging.optimizedCaption")
            fraction = 1
        case .manualLimit, .unavailable, nil:
            value = L10n.text("common.none")
            caption = L10n.text("battery.charging.unknownCaption")
            fraction = nil
        }
    }
}
