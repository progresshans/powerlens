import Foundation

extension TelemetrySnapshot {
    var chargeHealthPercent: Double? {
        guard let fullChargeCapacityMah, let designCapacityMah, designCapacityMah > 0 else { return nil }
        return Double(fullChargeCapacityMah) / Double(designCapacityMah) * 100
    }

    var batteryHealthSummary: String {
        if isServiceRecommended {
            return L10n.text("health.serviceRecommended")
        }

        if let health = chargeHealthPercent {
            return health >= 85 ? L10n.text("health.normal") : L10n.text("health.aged")
        }

        return L10n.localizedBatteryHealth(batteryHealthText)
    }

    var macOSCapacityPercent: Double? {
        guard let nominalCapacityMah, let designCapacityMah, designCapacityMah > 0 else { return nil }
        return Double(nominalCapacityMah) / Double(designCapacityMah) * 100
    }

    private var isServiceRecommended: Bool {
        batteryHealthText == "Service Recommended" || batteryHealthCondition == "Service Recommended"
    }
}
