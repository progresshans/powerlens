import Foundation

struct TelemetrySystemKeyPath: Equatable, Hashable, Sendable {
    let components: [String]

    init(_ key: String) {
        components = [key]
    }

    init(parent: String, child: String) {
        components = [parent, child]
    }

    var path: String {
        components.joined(separator: ".")
    }
}

/// System dictionary keys consumed by PowerLens telemetry readers.
///
/// The application and the compatibility probe both use these enums. The
/// external macOS profile remains an independent expectation so an accidental
/// contract change cannot update both sides of the CI comparison at once.
enum TelemetrySystemContract {
    enum IOPowerSourceKey: String, CaseIterable, Sendable {
        case currentCapacity = "Current Capacity"
        case powerSourceState = "Power Source State"
        case isCharging = "Is Charging"
        case isCharged = "Is Charged"
        case timeToEmpty = "Time to Empty"
        case timeToFullCharge = "Time to Full Charge"
        case batteryHealth = "BatteryHealth"
        case batteryHealthCondition = "BatteryHealthCondition"
        case hardwareSerialNumber = "Hardware Serial Number"
    }

    enum ExternalPowerAdapterKey: String, CaseIterable, Sendable {
        case description = "Description"
        case watts = "Watts"
        case voltage = "Voltage"
        case current = "Current"
    }

    enum AppleSmartBatteryKey: String, CaseIterable, Sendable {
        case voltage = "Voltage"
        case amperage = "Amperage"
        case powerTelemetryData = "PowerTelemetryData"
        case externalConnected = "ExternalConnected"
        case isCharging = "IsCharging"
        case fullyCharged = "FullyCharged"
        case designCapacity = "DesignCapacity"
        case rawMaxCapacity = "AppleRawMaxCapacity"
        case nominalChargeCapacity = "NominalChargeCapacity"
        case cycleCount = "CycleCount"
        case designCycleCount = "DesignCycleCount9C"
        case temperature = "Temperature"
        case deviceName = "DeviceName"
        case serial = "Serial"
        case permanentFailureStatus = "PermanentFailureStatus"
        case batteryData = "BatteryData"
    }

    /// macOS 27.2 publishes capacities only inside `BatteryData`; earlier
    /// releases also publish them at the top level, which takes precedence.
    enum BatteryDataKey: String, CaseIterable, Sendable {
        case designCapacity = "DesignCapacity"
        case rawMaxCapacity = "AppleRawMaxCapacity"
        case nominalChargeCapacity = "NominalChargeCapacity"
    }

    enum PowerTelemetryKey: String, CaseIterable, Sendable {
        case batteryPower = "BatteryPower"
        case systemPowerIn = "SystemPowerIn"
        case systemLoad = "SystemLoad"
        case systemVoltageIn = "SystemVoltageIn"
        case systemCurrentIn = "SystemCurrentIn"
    }

    enum AppleSMCKey: String, CaseIterable, Sendable {
        case batteryPower = "SBAP"
        case externalPower = "PDTR"
        case systemPower = "PSTR"
        /// Battery temperature sensors in °C. macOS 27.2 no longer publishes
        /// the AppleSmartBattery `Temperature` key.
        case batteryTemperature0 = "TB0T"
        case batteryTemperature1 = "TB1T"
        case batteryTemperature2 = "TB2T"

        static let batteryTemperatures: [Self] = [
            .batteryTemperature0, .batteryTemperature1, .batteryTemperature2,
        ]
    }

    static let smcFloatDataType = "flt "
    static let smcFloatDataSize = 4

    static let ioPowerSourceKeyPaths = IOPowerSourceKey.allCases.map {
        TelemetrySystemKeyPath($0.rawValue)
    }

    static let externalPowerAdapterKeyPaths =
        ExternalPowerAdapterKey.allCases.map {
            TelemetrySystemKeyPath($0.rawValue)
        }

    static let appleSmartBatteryKeyPaths =
        AppleSmartBatteryKey.allCases.map {
            TelemetrySystemKeyPath($0.rawValue)
        } + PowerTelemetryKey.allCases.map {
            TelemetrySystemKeyPath(
                parent: AppleSmartBatteryKey.powerTelemetryData.rawValue,
                child: $0.rawValue
            )
        } + BatteryDataKey.allCases.map {
            TelemetrySystemKeyPath(
                parent: AppleSmartBatteryKey.batteryData.rawValue,
                child: $0.rawValue
            )
        }

}
