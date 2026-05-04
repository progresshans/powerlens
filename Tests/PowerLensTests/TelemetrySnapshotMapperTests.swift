import Foundation
import IOKit.ps
import Testing
@testable import PowerLens

struct TelemetrySnapshotMapperTests {
    @Test
    func compatibleMapperBuildsSnapshotFromIOPowerSourceData() throws {
        let snapshot = try CompatibleTelemetrySnapshotMapper(
            powerSourceInfo: [
                kIOPSPowerSourceStateKey: kIOPMACPowerKey,
                kIOPSCurrentCapacityKey: 72,
                kIOPSIsChargingKey: true,
                kIOPSIsChargedKey: false,
                kIOPSTimeToFullChargeKey: 44,
                "BatteryHealth": "Normal",
                "Hardware Serial Number": "SERIAL"
            ],
            adapterDetails: [
                "Description": "USB-C",
                "Watts": 67,
                "Voltage": 20.0,
                "Current": 3.35
            ],
            environment: makeEnvironment()
        ).snapshot()

        #expect(snapshot.powerSource == .ac)
        #expect(snapshot.batteryLevel == 72)
        #expect(snapshot.isCharging)
        #expect(snapshot.timeToFullMinutes == 44)
        #expect(snapshot.adapterDescription == "USB-C")
        #expect(snapshot.adapterMaxPowerW == 67)
        #expect(snapshot.frontmostAppName == "Codex")
    }

    @Test
    func livePrecisionMapperNormalizesNegativeBatteryCurrentToDischargingPower() throws {
        let snapshot = try LivePrecisionTelemetrySnapshotMapper(
            powerSourceInfo: [
                kIOPSPowerSourceStateKey: kIOPMBatteryPowerKey,
                kIOPSCurrentCapacityKey: 79
            ],
            batteryRegistry: [
                "ExternalConnected": false,
                "Voltage": 12_250,
                "Amperage": -820
            ],
            adapterDetails: [:],
            smcPower: nil,
            environment: makeEnvironment()
        ).snapshot()

        #expect(snapshot.batteryCurrentA == -0.82)
        #expect(abs((snapshot.batteryPowerW ?? 0) - 10.045) < 0.001)
        #expect(!snapshot.isBatteryChargingForDisplay)
        #expect(snapshot.externalPowerState == .onBattery)
    }

    @Test
    func livePrecisionMapperNormalizesPositiveBatteryCurrentToChargingPower() throws {
        let snapshot = try LivePrecisionTelemetrySnapshotMapper(
            powerSourceInfo: [
                kIOPSPowerSourceStateKey: kIOPMACPowerKey,
                kIOPSCurrentCapacityKey: 80
            ],
            batteryRegistry: [
                "ExternalConnected": true,
                "Voltage": 12_630,
                "Amperage": 3_440
            ],
            adapterDetails: [:],
            smcPower: nil,
            environment: makeEnvironment()
        ).snapshot()

        #expect(snapshot.batteryCurrentA == 3.44)
        #expect(abs((snapshot.batteryPowerW ?? 0) - -43.4472) < 0.001)
        #expect(snapshot.isBatteryChargingForDisplay)
        #expect(snapshot.externalPowerState == .charging)
    }

    @Test
    func livePrecisionMapperPrefersSMCPowerWhenAvailable() throws {
        let snapshot = try LivePrecisionTelemetrySnapshotMapper(
            powerSourceInfo: [
                kIOPSPowerSourceStateKey: kIOPMACPowerKey,
                kIOPSCurrentCapacityKey: 80
            ],
            batteryRegistry: [
                "ExternalConnected": true,
                "Voltage": 12_630,
                "Amperage": 3_440,
                "PowerTelemetryData": [
                    "BatteryPower": -12_000,
                    "SystemPowerIn": 52_000,
                    "SystemLoad": 8_000
                ]
            ],
            adapterDetails: [:],
            smcPower: SMCPowerSnapshot(batteryPowerW: -9.8, externalPowerW: 51.2, systemPowerW: 7.4),
            environment: makeEnvironment()
        ).snapshot()

        #expect(snapshot.batteryPowerW == -9.8)
        #expect(snapshot.adapterInputPowerW == 51.2)
        #expect(snapshot.systemLoadW == 7.4)
    }
}

private func makeEnvironment() -> TelemetryReadEnvironment {
    TelemetryReadEnvironment(
        lowPowerModeEnabled: false,
        thermalState: .nominal,
        frontmostApplication: FrontmostApplicationInfo(
            bundleIdentifier: "com.openai.codex",
            localizedName: "Codex"
        )
    )
}
