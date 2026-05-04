import Foundation
import IOKit.ps

struct CompatibleTelemetrySnapshotMapper {
    let powerSourceInfo: [String: Any]
    let adapterDetails: [String: Any]
    let environment: TelemetryReadEnvironment

    func snapshot() throws -> TelemetrySnapshot {
        guard !powerSourceInfo.isEmpty else {
            throw TelemetryReadError.unavailable
        }

        let powerSource = TelemetryValueParser.parsePowerSource(powerSourceInfo[kIOPSPowerSourceStateKey] as? String)
        let frontmostApp = environment.frontmostApplication

        return TelemetrySnapshot(
            batteryLevel: TelemetryValueParser.doubleValue(powerSourceInfo[kIOPSCurrentCapacityKey]),
            powerSource: powerSource,
            isCharging: TelemetryValueParser.boolValue(powerSourceInfo[kIOPSIsChargingKey]) ?? false,
            isCharged: TelemetryValueParser.boolValue(powerSourceInfo[kIOPSIsChargedKey]) ?? false,
            externalConnected: powerSource == .ac,
            timeToEmptyMinutes: TelemetryValueParser.sanitize(
                minutes: TelemetryValueParser.intValue(powerSourceInfo[kIOPSTimeToEmptyKey])
            ),
            timeToFullMinutes: TelemetryValueParser.sanitize(
                minutes: TelemetryValueParser.intValue(powerSourceInfo[kIOPSTimeToFullChargeKey])
            ),
            designCapacityMah: nil,
            fullChargeCapacityMah: nil,
            nominalCapacityMah: nil,
            cycleCount: nil,
            designCycleCount: nil,
            batteryHealthText: TelemetryValueParser.nonEmptyString(powerSourceInfo["BatteryHealth"]),
            batteryHealthCondition: TelemetryValueParser.nonEmptyString(powerSourceInfo["BatteryHealthCondition"]),
            batteryTemperatureC: nil,
            batteryVoltageV: nil,
            batteryCurrentA: nil,
            batteryPowerW: nil,
            adapterDescription: TelemetryValueParser.nonEmptyString(adapterDetails["Description"]),
            adapterMaxPowerW: TelemetryValueParser.doubleValue(adapterDetails["Watts"]),
            adapterInputPowerW: nil,
            adapterVoltageV: TelemetryValueParser.doubleValue(adapterDetails["Voltage"]),
            adapterCurrentA: TelemetryValueParser.doubleValue(adapterDetails["Current"]),
            systemLoadW: nil,
            lowPowerModeEnabled: environment.lowPowerModeEnabled,
            thermalState: TelemetryValueParser.describe(environment.thermalState),
            serialNumber: TelemetryValueParser.nonEmptyString(powerSourceInfo["Hardware Serial Number"]),
            frontmostAppBundleID: frontmostApp?.bundleIdentifier,
            frontmostAppName: frontmostApp?.localizedName
        )
    }
}

struct LivePrecisionTelemetrySnapshotMapper {
    let powerSourceInfo: [String: Any]
    let batteryRegistry: [String: Any]
    let adapterDetails: [String: Any]
    let smcPower: SMCPowerSnapshot?
    let environment: TelemetryReadEnvironment

    func snapshot() throws -> TelemetrySnapshot {
        guard !powerSourceInfo.isEmpty, !batteryRegistry.isEmpty else {
            throw TelemetryReadError.unavailable
        }

        let telemetry = batteryRegistry["PowerTelemetryData"] as? [String: Any] ?? [:]
        let powerSource = TelemetryValueParser.parsePowerSource(powerSourceInfo[kIOPSPowerSourceStateKey] as? String)
        let batteryVoltageV = TelemetryValueParser.doubleValue(batteryRegistry["Voltage"]).map { $0 / 1000 }
        let batteryCurrentA = TelemetryValueParser.doubleValue(batteryRegistry["Amperage"]).map { $0 / 1000 }
        let frontmostApp = environment.frontmostApplication

        return TelemetrySnapshot(
            batteryLevel: TelemetryValueParser.doubleValue(powerSourceInfo[kIOPSCurrentCapacityKey]),
            powerSource: powerSource,
            isCharging: TelemetryValueParser.boolValue(powerSourceInfo[kIOPSIsChargingKey])
                ?? TelemetryValueParser.boolValue(batteryRegistry["IsCharging"])
                ?? false,
            isCharged: TelemetryValueParser.boolValue(powerSourceInfo[kIOPSIsChargedKey])
                ?? TelemetryValueParser.boolValue(batteryRegistry["FullyCharged"])
                ?? false,
            externalConnected: TelemetryValueParser.boolValue(batteryRegistry["ExternalConnected"]) ?? (powerSource == .ac),
            timeToEmptyMinutes: TelemetryValueParser.sanitize(
                minutes: TelemetryValueParser.intValue(powerSourceInfo[kIOPSTimeToEmptyKey])
            ),
            timeToFullMinutes: TelemetryValueParser.sanitize(
                minutes: TelemetryValueParser.intValue(powerSourceInfo[kIOPSTimeToFullChargeKey])
            ),
            designCapacityMah: TelemetryValueParser.intValue(batteryRegistry["DesignCapacity"]),
            fullChargeCapacityMah: TelemetryValueParser.intValue(batteryRegistry["AppleRawMaxCapacity"]),
            nominalCapacityMah: TelemetryValueParser.intValue(batteryRegistry["NominalChargeCapacity"]),
            cycleCount: TelemetryValueParser.intValue(batteryRegistry["CycleCount"]),
            designCycleCount: TelemetryValueParser.intValue(batteryRegistry["DesignCycleCount9C"]),
            batteryHealthText: TelemetryValueParser.nonEmptyString(powerSourceInfo["BatteryHealth"])
                ?? TelemetryValueParser.inferredHealthText(from: batteryRegistry),
            batteryHealthCondition: TelemetryValueParser.nonEmptyString(powerSourceInfo["BatteryHealthCondition"]),
            batteryTemperatureC: TelemetryValueParser.doubleValue(batteryRegistry["Temperature"]).map { $0 / 100 },
            batteryVoltageV: batteryVoltageV,
            batteryCurrentA: batteryCurrentA,
            batteryPowerW: smcPower?.batteryPowerW
                ?? TelemetryValueParser.milliwattsValue(telemetry["BatteryPower"])
                ?? computedBatteryPowerW(voltage: batteryVoltageV, current: batteryCurrentA),
            adapterDescription: TelemetryValueParser.nonEmptyString(adapterDetails["Description"])
                ?? TelemetryValueParser.nonEmptyString(batteryRegistry["DeviceName"]),
            adapterMaxPowerW: TelemetryValueParser.doubleValue(adapterDetails["Watts"]),
            adapterInputPowerW: smcPower?.externalPowerW
                ?? TelemetryValueParser.milliwattsValue(telemetry["SystemPowerIn"]),
            adapterVoltageV: TelemetryValueParser.doubleValue(telemetry["SystemVoltageIn"]).map { $0 / 1000 },
            adapterCurrentA: TelemetryValueParser.doubleValue(telemetry["SystemCurrentIn"]).map { $0 / 1000 },
            systemLoadW: smcPower?.systemPowerW ?? TelemetryValueParser.milliwattsValue(telemetry["SystemLoad"]),
            lowPowerModeEnabled: environment.lowPowerModeEnabled,
            thermalState: TelemetryValueParser.describe(environment.thermalState),
            serialNumber: TelemetryValueParser.nonEmptyString(powerSourceInfo["Hardware Serial Number"])
                ?? TelemetryValueParser.nonEmptyString(batteryRegistry["Serial"]),
            frontmostAppBundleID: frontmostApp?.bundleIdentifier,
            frontmostAppName: frontmostApp?.localizedName
        )
    }

    private func computedBatteryPowerW(voltage: Double?, current: Double?) -> Double? {
        guard let voltage, let current else {
            return nil
        }

        // AppleSmartBattery amperage is negative while discharging. PowerLens normalizes
        // battery power to positive = battery supports load, negative = battery charges.
        return -(current * voltage)
    }
}
