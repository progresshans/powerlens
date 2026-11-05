import Foundation

/// Battery temperature and system thermal pressure are independent readings.
/// Keep the existing diagnostic threshold and reuse the existing copy. The
/// bands match the Battery page chart: warm from 36°C, hot from 40°C.
enum BatteryTemperatureAssessment: Equatable {
    static let elevatedThreshold = 36.0
    static let hotThreshold = 40.0
    static let chartMaximum = 45.0

    case unknown
    case normal
    case elevated
    case hot

    init(_ celsius: Double?) {
        guard let celsius, celsius.isFinite else {
            self = .unknown
            return
        }
        self = if celsius >= Self.hotThreshold {
            .hot
        } else if celsius >= Self.elevatedThreshold {
            .elevated
        } else {
            .normal
        }
    }

    /// Warm enough that charging may slow down.
    var isAboveNormal: Bool { self == .elevated || self == .hot }

    var tone: StatusTone {
        switch self {
        case .unknown, .normal: .neutral
        case .elevated: .caution
        case .hot: .warning
        }
    }

    var caption: String {
        switch self {
        case .unknown: L10n.text("thermal.unknown")
        case .normal: L10n.text("thermal.nominal")
        case .elevated: L10n.text("thermal.fair")
        case .hot: L10n.text("thermal.serious")
        }
    }
}
