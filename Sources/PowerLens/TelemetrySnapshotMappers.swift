import Foundation

struct CompatibleTelemetrySnapshotMapper {
    let powerSourceInfo: [String: Any]
    let adapterDetails: [String: Any]
    let environment: TelemetryReadEnvironment

    func snapshot() throws -> TelemetrySnapshot {
        guard !powerSourceInfo.isEmpty else {
            throw TelemetryReadError.unavailable
        }

        let powerSource = TelemetryValueParser.parsePowerSource(
            powerSourceInfo[key(.powerSourceState)] as? String
        )
        let frontmostApp = environment.frontmostApplication

        return TelemetrySnapshot(
            batteryLevel: TelemetryValueParser.doubleValue(
                powerSourceInfo[key(.currentCapacity)]
            ),
            powerSource: powerSource,
            isCharging: TelemetryValueParser.boolValue(
                powerSourceInfo[key(.isCharging)]
            ) ?? false,
            isCharged: TelemetryValueParser.boolValue(
                powerSourceInfo[key(.isCharged)]
            ) ?? false,
            externalConnected: powerSource == .ac,
            timeToEmptyMinutes: TelemetryValueParser.sanitize(
                minutes: TelemetryValueParser.intValue(
                    powerSourceInfo[key(.timeToEmpty)]
                )
            ),
            timeToFullMinutes: TelemetryValueParser.sanitize(
                minutes: TelemetryValueParser.intValue(
                    powerSourceInfo[key(.timeToFullCharge)]
                )
            ),
            designCapacityMah: nil,
            fullChargeCapacityMah: nil,
            nominalCapacityMah: nil,
            cycleCount: nil,
            designCycleCount: nil,
            batteryHealthText: TelemetryValueParser.nonEmptyString(
                powerSourceInfo[key(.batteryHealth)]
            ),
            batteryHealthCondition: TelemetryValueParser.nonEmptyString(
                powerSourceInfo[key(.batteryHealthCondition)]
            ),
            batteryTemperatureC: nil,
            batteryVoltageV: nil,
            batteryCurrentA: nil,
            batteryPowerW: nil,
            adapterDescription: TelemetryValueParser.nonEmptyString(
                adapterDetails[adapterKey(.description)]
            ),
            adapterMaxPowerW: TelemetryValueParser.doubleValue(
                adapterDetails[adapterKey(.watts)]
            ),
            adapterInputPowerW: nil,
            adapterVoltageV: positiveElectricalValue(
                adapterDetails[adapterKey(.voltage)]
            ),
            adapterCurrentA: positiveElectricalValue(
                adapterDetails[adapterKey(.current)]
            ),
            systemLoadW: nil,
            lowPowerModeEnabled: environment.lowPowerModeEnabled,
            thermalState: TelemetryValueParser.describe(environment.thermalState),
            serialNumber: TelemetryValueParser.nonEmptyString(
                powerSourceInfo[key(.hardwareSerialNumber)]
            ),
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

        let telemetry = batteryRegistry[batteryKey(.powerTelemetryData)]
            as? [String: Any] ?? [:]
        let powerSource = TelemetryValueParser.parsePowerSource(
            powerSourceInfo[key(.powerSourceState)] as? String
        )
        let batteryVoltageV = TelemetryValueParser.doubleValue(
            batteryRegistry[batteryKey(.voltage)]
        ).map { $0 / 1000 }
        let batteryCurrentA = TelemetryValueParser.doubleValue(
            batteryRegistry[batteryKey(.amperage)]
        ).map { $0 / 1000 }
        let powerMeasurements = resolvePowerMeasurements(
            telemetry: telemetry,
            voltageV: batteryVoltageV,
            currentA: batteryCurrentA
        )
        let frontmostApp = environment.frontmostApplication

        return TelemetrySnapshot(
            batteryLevel: TelemetryValueParser.doubleValue(
                powerSourceInfo[key(.currentCapacity)]
            ),
            powerSource: powerSource,
            isCharging: TelemetryValueParser.boolValue(
                powerSourceInfo[key(.isCharging)]
            )
                ?? TelemetryValueParser.boolValue(
                    batteryRegistry[batteryKey(.isCharging)]
                )
                ?? false,
            isCharged: TelemetryValueParser.boolValue(
                powerSourceInfo[key(.isCharged)]
            )
                ?? TelemetryValueParser.boolValue(
                    batteryRegistry[batteryKey(.fullyCharged)]
                )
                ?? false,
            externalConnected: TelemetryValueParser.boolValue(
                batteryRegistry[batteryKey(.externalConnected)]
            ) ?? (powerSource == .ac),
            timeToEmptyMinutes: TelemetryValueParser.sanitize(
                minutes: TelemetryValueParser.intValue(
                    powerSourceInfo[key(.timeToEmpty)]
                )
            ),
            timeToFullMinutes: TelemetryValueParser.sanitize(
                minutes: TelemetryValueParser.intValue(
                    powerSourceInfo[key(.timeToFullCharge)]
                )
            ),
            designCapacityMah: TelemetryValueParser.intValue(
                batteryRegistry[batteryKey(.designCapacity)]
            ),
            fullChargeCapacityMah: TelemetryValueParser.intValue(
                batteryRegistry[batteryKey(.rawMaxCapacity)]
            ),
            nominalCapacityMah: TelemetryValueParser.intValue(
                batteryRegistry[batteryKey(.nominalChargeCapacity)]
            ),
            cycleCount: TelemetryValueParser.intValue(
                batteryRegistry[batteryKey(.cycleCount)]
            ),
            designCycleCount: TelemetryValueParser.intValue(
                batteryRegistry[batteryKey(.designCycleCount)]
            ),
            batteryHealthText: TelemetryValueParser.nonEmptyString(
                powerSourceInfo[key(.batteryHealth)]
            )
                ?? TelemetryValueParser.inferredHealthText(from: batteryRegistry),
            batteryHealthCondition: TelemetryValueParser.nonEmptyString(
                powerSourceInfo[key(.batteryHealthCondition)]
            ),
            batteryTemperatureC: TelemetryValueParser.doubleValue(
                batteryRegistry[batteryKey(.temperature)]
            ).map { $0 / 100 },
            batteryVoltageV: batteryVoltageV,
            batteryCurrentA: batteryCurrentA,
            batteryPowerW: powerMeasurements.batteryPowerW,
            batteryPowerSource: powerMeasurements.batteryPowerSource,
            adapterDescription: TelemetryValueParser.nonEmptyString(
                adapterDetails[adapterKey(.description)]
            ) ?? TelemetryValueParser.nonEmptyString(
                batteryRegistry[batteryKey(.deviceName)]
            ),
            adapterMaxPowerW: TelemetryValueParser.doubleValue(
                adapterDetails[adapterKey(.watts)]
            ),
            adapterInputPowerW: powerMeasurements.adapterInputPowerW,
            adapterVoltageV: positiveElectricalValue(
                telemetry[telemetryKey(.systemVoltageIn)],
                dividedBy: 1000
            ),
            adapterCurrentA: positiveElectricalValue(
                telemetry[telemetryKey(.systemCurrentIn)],
                dividedBy: 1000
            ),
            systemLoadW: powerMeasurements.systemLoadW,
            powerMeasurementSetSource: powerMeasurements.setSource,
            lowPowerModeEnabled: environment.lowPowerModeEnabled,
            thermalState: TelemetryValueParser.describe(environment.thermalState),
            serialNumber: TelemetryValueParser.nonEmptyString(
                powerSourceInfo[key(.hardwareSerialNumber)]
            ) ?? TelemetryValueParser.nonEmptyString(
                batteryRegistry[batteryKey(.serial)]
            ),
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
            telemetry[telemetryKey(.batteryPower)]
        ).map { -$0 }
        let telemetryInputPowerW = TelemetryValueParser.milliwattsValue(
            telemetry[telemetryKey(.systemPowerIn)]
        )
        let telemetrySystemLoadW = TelemetryValueParser.milliwattsValue(
            telemetry[telemetryKey(.systemLoad)]
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

private func key(
    _ key: TelemetrySystemContract.IOPowerSourceKey
) -> String {
    key.rawValue
}

private func adapterKey(
    _ key: TelemetrySystemContract.ExternalPowerAdapterKey
) -> String {
    key.rawValue
}

private func batteryKey(
    _ key: TelemetrySystemContract.AppleSmartBatteryKey
) -> String {
    key.rawValue
}

private func telemetryKey(
    _ key: TelemetrySystemContract.PowerTelemetryKey
) -> String {
    key.rawValue
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
