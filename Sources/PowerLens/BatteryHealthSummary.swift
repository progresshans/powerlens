import Foundation

/// What PowerLens can say about battery health: computed capacity first, then
/// the macOS health text. Missing evidence is `unknown`, never healthy.
enum BatteryHealthAssessment: Equatable, Sendable {
    case normal
    case aged
    case checkBattery
    case serviceRecommended
    case unknown
}

extension TelemetrySnapshot {
    var chargeHealthPercent: Double? {
        guard let fullChargeCapacityMah, let designCapacityMah, designCapacityMah > 0 else { return nil }
        return Double(fullChargeCapacityMah) / Double(designCapacityMah) * 100
    }

    var batteryHealthAssessment: BatteryHealthAssessment {
        if isServiceRecommended {
            return .serviceRecommended
        }

        if let health = chargeHealthPercent {
            return health >= 85 ? .normal : .aged
        }

        switch batteryHealthText {
        case "Normal": return .normal
        case "Aged": return .aged
        case "Check Battery": return .checkBattery
        default: return .unknown
        }
    }

    var batteryHealthSummary: String {
        switch batteryHealthAssessment {
        case .serviceRecommended: L10n.text("health.serviceRecommended")
        case .normal: L10n.text("health.normal")
        case .aged: L10n.text("health.aged")
        case .checkBattery: L10n.text("health.checkBattery")
        // An unrecognized macOS value is shown as reported.
        case .unknown: L10n.localizedBatteryHealth(batteryHealthText)
        }
    }

    var macOSCapacityPercent: Double? {
        guard let nominalCapacityMah, let designCapacityMah, designCapacityMah > 0 else { return nil }
        return Double(nominalCapacityMah) / Double(designCapacityMah) * 100
    }

    private var isServiceRecommended: Bool {
        batteryHealthText == "Service Recommended" || batteryHealthCondition == "Service Recommended"
    }
}
