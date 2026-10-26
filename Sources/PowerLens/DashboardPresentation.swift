import Foundation

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
