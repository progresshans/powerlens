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
            adapterVoltageV: positiveElectricalValue(adapterDetails["Voltage"]),
            adapterCurrentA: positiveElectricalValue(adapterDetails["Current"]),
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
    private struct ResolvedPowerMeasurements {
        let batteryPowerW: Double?
        let batteryPowerSource: BatteryPowerSource?
        let adapterInputPowerW: Double?
        let systemLoadW: Double?
        let setSource: PowerMeasurementSetSource?
    }

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
        let powerMeasurements = resolvePowerMeasurements(
            telemetry: telemetry,
            voltageV: batteryVoltageV,
            currentA: batteryCurrentA
        )
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
            batteryPowerW: powerMeasurements.batteryPowerW,
            batteryPowerSource: powerMeasurements.batteryPowerSource,
            adapterDescription: TelemetryValueParser.nonEmptyString(adapterDetails["Description"])
                ?? TelemetryValueParser.nonEmptyString(batteryRegistry["DeviceName"]),
            adapterMaxPowerW: TelemetryValueParser.doubleValue(adapterDetails["Watts"]),
            adapterInputPowerW: powerMeasurements.adapterInputPowerW,
            adapterVoltageV: positiveElectricalValue(
                telemetry["SystemVoltageIn"],
                dividedBy: 1000
            ),
            adapterCurrentA: positiveElectricalValue(
                telemetry["SystemCurrentIn"],
                dividedBy: 1000
            ),
            systemLoadW: powerMeasurements.systemLoadW,
            powerMeasurementSetSource: powerMeasurements.setSource,
            lowPowerModeEnabled: environment.lowPowerModeEnabled,
            thermalState: TelemetryValueParser.describe(environment.thermalState),
            serialNumber: TelemetryValueParser.nonEmptyString(powerSourceInfo["Hardware Serial Number"])
                ?? TelemetryValueParser.nonEmptyString(batteryRegistry["Serial"]),
            frontmostAppBundleID: frontmostApp?.bundleIdentifier,
            frontmostAppName: frontmostApp?.localizedName
        )
    }

    private func resolvePowerMeasurements(
        telemetry: [String: Any],
        voltageV: Double?,
        currentA: Double?
    ) -> ResolvedPowerMeasurements {
        // SBAP already follows PowerLens' convention (positive discharging,
        // negative charging). PowerTelemetryData follows battery amperage, so
        // its BatteryPower sign must be inverted at the provider boundary.
        let telemetryBatteryPowerW = TelemetryValueParser.milliwattsValue(
            telemetry["BatteryPower"]
        ).map { -$0 }
        let telemetryInputPowerW = TelemetryValueParser.milliwattsValue(
            telemetry["SystemPowerIn"]
        )
        let telemetrySystemLoadW = TelemetryValueParser.milliwattsValue(
            telemetry["SystemLoad"]
        )

        if let batteryPowerW = smcPower?.batteryPowerW,
           let adapterInputPowerW = smcPower?.externalPowerW,
           let systemLoadW = smcPower?.systemPowerW {
            return ResolvedPowerMeasurements(
                batteryPowerW: batteryPowerW,
                batteryPowerSource: .directTelemetry,
                adapterInputPowerW: adapterInputPowerW,
                systemLoadW: systemLoadW,
                setSource: .smc
            )
        }

        if let batteryPowerW = telemetryBatteryPowerW,
           let adapterInputPowerW = telemetryInputPowerW,
           let systemLoadW = telemetrySystemLoadW {
            return ResolvedPowerMeasurements(
                batteryPowerW: batteryPowerW,
                batteryPowerSource: .directTelemetry,
                adapterInputPowerW: adapterInputPowerW,
                systemLoadW: systemLoadW,
                setSource: .powerTelemetry
            )
        }

        let directBatteryPowerW = smcPower?.batteryPowerW
            ?? telemetryBatteryPowerW
        let batteryPower = resolveBatteryPower(
            directPowerW: directBatteryPowerW,
            voltageV: voltageV,
            currentA: currentA
        )
        return ResolvedPowerMeasurements(
            batteryPowerW: batteryPower.valueW,
            batteryPowerSource: batteryPower.source,
            adapterInputPowerW: smcPower?.externalPowerW
                ?? telemetryInputPowerW,
            systemLoadW: smcPower?.systemPowerW ?? telemetrySystemLoadW,
            setSource: nil
        )
    }

    private func resolveBatteryPower(
        directPowerW: Double?,
        voltageV: Double?,
        currentA: Double?
    ) -> (valueW: Double?, source: BatteryPowerSource?) {
        if let directPowerW {
            return (directPowerW, .directTelemetry)
        }

        guard let voltageV, let currentA else {
            return (nil, nil)
        }

        // AppleSmartBattery amperage is negative while discharging. PowerLens
        // normalizes battery power to positive = supporting the system and
        // negative = charging.
        return (-(currentA * voltageV), .currentAndVoltage)
    }
}

private func positiveElectricalValue(
    _ value: Any?,
    dividedBy divisor: Double = 1
) -> Double? {
    guard let value = TelemetryValueParser.doubleValue(value),
          value.isFinite,
          value > 0 else {
        return nil
    }
    return value / divisor
}
