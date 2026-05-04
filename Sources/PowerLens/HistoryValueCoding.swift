import Foundation

enum HistoryValueCoding {
    static func stringComponent<T>(_ value: T?) -> String {
        guard let value else { return "_" }
        return String(describing: value)
    }

    static func tenthsPercent(from value: Double?) -> Int? {
        value.map { Int(($0 * 10).rounded()) }
    }

    static func percent(fromTenths value: Int?) -> Double? {
        value.map { Double($0) / 10 }
    }

    static func celsiusHundredths(from value: Double?) -> Int? {
        value.map { Int(($0 * 100).rounded()) }
    }

    static func celsius(fromHundredths value: Int?) -> Double? {
        value.map { Double($0) / 100 }
    }

    static func millivolts(from value: Double?) -> Int? {
        value.map { Int(($0 * 1000).rounded()) }
    }

    static func volts(fromMillivolts value: Int?) -> Double? {
        value.map { Double($0) / 1000 }
    }

    static func milliamps(from value: Double?) -> Int? {
        value.map { Int(($0 * 1000).rounded()) }
    }

    static func amps(fromMilliamps value: Int?) -> Double? {
        value.map { Double($0) / 1000 }
    }

    static func milliwatts(from value: Double?) -> Int? {
        value.map { Int(($0 * 1000).rounded()) }
    }

    static func watts(fromMilliwatts value: Int?) -> Double? {
        value.map { Double($0) / 1000 }
    }

    static func powerSourceCode(_ kind: PowerSourceKind) -> Int32 {
        switch kind {
        case .unknown:
            0
        case .ac:
            1
        case .battery:
            2
        case .offline:
            3
        }
    }

    static func powerSourceKind(from code: Int32) -> PowerSourceKind? {
        switch code {
        case 1:
            .ac
        case 2:
            .battery
        case 3:
            .offline
        default:
            .unknown
        }
    }

    static func thermalStateCode(_ name: String) -> Int32 {
        switch name {
        case "Nominal":
            1
        case "Fair":
            2
        case "Serious":
            3
        case "Critical":
            4
        default:
            0
        }
    }

    static func thermalStateName(from code: Int32) -> String {
        switch code {
        case 1:
            "Nominal"
        case 2:
            "Fair"
        case 3:
            "Serious"
        case 4:
            "Critical"
        default:
            "Unknown"
        }
    }
}
