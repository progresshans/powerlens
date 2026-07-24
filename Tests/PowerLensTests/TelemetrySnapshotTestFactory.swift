import Foundation
@testable import PowerLens

func makeTelemetrySnapshot(
    timestamp: Date = Date(timeIntervalSince1970: 1_775_000_000),
    batteryLevel: Double? = 80,
    powerSource: PowerSourceKind = .ac,
    isCharging: Bool = false,
    isCharged: Bool = false,
    externalConnected: Bool = true,
    timeToEmptyMinutes: Int? = nil,
    timeToFullMinutes: Int? = nil,
    batteryCurrentA: Double? = 0,
    batteryPowerW: Double? = 0,
    adapterInputPowerW: Double? = 11,
    systemLoadW: Double? = 10,
    adapterMaxPowerW: Double? = 97,
    chargingPolicyStatus: ObservedChargingPolicyStatus? = nil
) -> TelemetrySnapshot {
    TelemetrySnapshot(
        timestamp: timestamp,
        batteryLevel: batteryLevel,
        powerSource: powerSource,
        isCharging: isCharging,
        isCharged: isCharged,
        externalConnected: externalConnected,
        timeToEmptyMinutes: timeToEmptyMinutes,
        timeToFullMinutes: timeToFullMinutes,
        designCapacityMah: 6249,
        fullChargeCapacityMah: 5639,
        nominalCapacityMah: 5791,
        cycleCount: 75,
        designCycleCount: 1000,
        batteryHealthText: "Normal",
        batteryHealthCondition: nil,
        batteryTemperatureC: 30.2,
        batteryVoltageV: 12.25,
        batteryCurrentA: batteryCurrentA,
        batteryPowerW: batteryPowerW,
        adapterDescription: "PD Charger",
        adapterMaxPowerW: adapterMaxPowerW,
        adapterInputPowerW: adapterInputPowerW,
        adapterVoltageV: 19.5,
        adapterCurrentA: 0.6,
        systemLoadW: systemLoadW,
        lowPowerModeEnabled: false,
        thermalState: "Nominal",
        serialNumber: "SERIAL",
        frontmostAppName: "PowerLens",
        chargingPolicyStatus: chargingPolicyStatus
    )
}
