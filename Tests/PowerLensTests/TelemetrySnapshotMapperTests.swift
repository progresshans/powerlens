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
        #expect(snapshot.adapterVoltageV == 20)
        #expect(snapshot.adapterCurrentA == 3.35)
        #expect(snapshot.frontmostAppName == "Codex")
    }

    @Test
    func livePrecisionMapperPreservesCurrentDerivedDischargeWithItsSource() throws {
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
        #expect(snapshot.batteryPowerSource == .currentAndVoltage)
        #expect(
            abs((snapshot.measuredBatteryDischargeW ?? 0) - 10.045)
                < 0.001
        )
        #expect(!snapshot.isBatteryChargingForDisplay)
        #expect(snapshot.externalPowerState == .onBattery)
        #expect(snapshot.primaryDisplayedPowerW == snapshot.batteryPowerW)

        let flow = PowerFlowPresentationModel(snapshot: snapshot)
        #expect(flow.state == .discharging)
        #expect(flow.showsIndependentReadingsNotice)
        #expect(flow.routes.first?.source.value == "≈10.0W")
    }

    @Test
    func livePrecisionMapperPreservesCurrentDerivedChargeWithItsSource() throws {
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
        #expect(
            abs((snapshot.batteryPowerW ?? 0) - -43.4472) < 0.001
        )
        #expect(snapshot.batteryPowerSource == .currentAndVoltage)
        #expect(
            abs((snapshot.measuredBatteryChargeW ?? 0) - 43.4472)
                < 0.001
        )
        #expect(snapshot.isBatteryChargingForDisplay)
        #expect(snapshot.externalPowerState == .charging)

        let flow = PowerFlowPresentationModel(snapshot: snapshot)
        #expect(flow.state == .charging)
        #expect(flow.showsIndependentReadingsNotice)
        #expect(flow.routes[1].target.value == "≈43.4W")
    }

    @Test
    func livePrecisionMapperNormalizesPowerTelemetryChargingPower() throws {
        let snapshot = try LivePrecisionTelemetrySnapshotMapper(
            powerSourceInfo: [
                kIOPSPowerSourceStateKey: kIOPMACPowerKey,
                kIOPSCurrentCapacityKey: 80
            ],
            batteryRegistry: [
                "ExternalConnected": true,
                "Voltage": 12_630,
                "Amperage": 950,
                "PowerTelemetryData": [
                    "BatteryPower": 12_000,
                    "SystemPowerIn": 19_200,
                    "SystemLoad": 7_200
                ]
            ],
            adapterDetails: [:],
            smcPower: nil,
            environment: makeEnvironment()
        ).snapshot()

        #expect(snapshot.batteryPowerW == -12)
        #expect(snapshot.batteryPowerSource == .directTelemetry)
        #expect(snapshot.powerMeasurementSetSource == .powerTelemetry)

        let flow = PowerFlowPresentationModel(snapshot: snapshot)
        #expect(flow.state == .charging)
        #expect(!flow.showsIndependentReadingsNotice)
        #expect(flow.routes.last?.target.value == "12.0W")
    }

    @Test
    func livePrecisionMapperNormalizesPowerTelemetryDischargePower() throws {
        let snapshot = try LivePrecisionTelemetrySnapshotMapper(
            powerSourceInfo: [
                kIOPSPowerSourceStateKey: kIOPMACPowerKey,
                kIOPSCurrentCapacityKey: 80
            ],
            batteryRegistry: [
                "ExternalConnected": true,
                "Voltage": 12_630,
                "Amperage": -950,
                "PowerTelemetryData": [
                    "BatteryPower": -12_000,
                    "SystemPowerIn": 7_200,
                    "SystemLoad": 19_200
                ]
            ],
            adapterDetails: [:],
            smcPower: nil,
            environment: makeEnvironment()
        ).snapshot()

        #expect(snapshot.batteryPowerW == 12)
        #expect(snapshot.batteryPowerSource == .directTelemetry)
        #expect(snapshot.powerMeasurementSetSource == .powerTelemetry)

        let flow = PowerFlowPresentationModel(snapshot: snapshot)
        #expect(flow.state == .underpowered)
        #expect(!flow.showsIndependentReadingsNotice)
        #expect(flow.routes.last?.source.value == "12.0W")
    }

    @Test
    func coherentSMCPowerSetDrivesFlowWhenInputElectricalTelemetryIsUnavailable() throws {
        let snapshot = try LivePrecisionTelemetrySnapshotMapper(
            powerSourceInfo: [
                kIOPSPowerSourceStateKey: kIOPMACPowerKey,
                kIOPSCurrentCapacityKey: 43,
                kIOPSIsChargingKey: false
            ],
            batteryRegistry: [
                "ExternalConnected": true,
                "Voltage": 11_670,
                "Amperage": -740,
                "PowerTelemetryData": [
                    "SystemVoltageIn": 0,
                    "SystemCurrentIn": 0
                ]
            ],
            adapterDetails: ["Watts": 96],
            smcPower: SMCPowerSnapshot(
                batteryPowerW: -73.9,
                externalPowerW: 82.9,
                systemPowerW: 8.8
            ),
            environment: makeEnvironment()
        ).snapshot()

        #expect(snapshot.adapterVoltageV == nil)
        #expect(snapshot.adapterCurrentA == nil)
        #expect(snapshot.powerMeasurementSetSource == .smc)
        #expect(snapshot.batteryFlowEvidence == .conflicted)
        #expect(snapshot.hasConflictingBatteryPowerMeasurements)
        #expect(!snapshot.hasCorroboratedPowerDeliveryShortfall)

        let detailRows = Dictionary(
            uniqueKeysWithValues: TelemetryDetailRows.powerSnapshot(snapshot)
        )
        #expect(
            detailRows[L10n.text("ui.detail.inputVoltage")]
                == L10n.text("common.none")
        )
        #expect(
            detailRows[L10n.text("ui.detail.inputCurrent")]
                == L10n.text("common.none")
        )

        let flow = PowerFlowPresentationModel(snapshot: snapshot)
        #expect(flow.state == .charging)
        #expect(flow.showsIndependentReadingsNotice)
        #expect(flow.routes.map(\.role) == [.input, .charge])
        #expect(flow.routes.first?.source.value == "82.9W")
        #expect(flow.routes.first?.target.value == "8.8W")
        #expect(flow.routes.last?.target.value == "73.9W")
    }

    @Test
    func mixedPowerProvidersDoNotOverrideConflictingBatteryDirection() throws {
        let snapshot = try LivePrecisionTelemetrySnapshotMapper(
            powerSourceInfo: [
                kIOPSPowerSourceStateKey: kIOPMACPowerKey,
                kIOPSCurrentCapacityKey: 43
            ],
            batteryRegistry: [
                "ExternalConnected": true,
                "Voltage": 11_670,
                "Amperage": -740,
                "PowerTelemetryData": [
                    "SystemPowerIn": 82_900,
                    "SystemLoad": 8_800
                ]
            ],
            adapterDetails: [:],
            smcPower: SMCPowerSnapshot(
                batteryPowerW: -73.9,
                externalPowerW: nil,
                systemPowerW: nil
            ),
            environment: makeEnvironment()
        ).snapshot()

        #expect(snapshot.batteryFlowEvidence == .conflicted)
        #expect(snapshot.powerMeasurementSetSource == nil)

        let flow = PowerFlowPresentationModel(snapshot: snapshot)
        #expect(flow.state == .unknown)
        #expect(flow.routes.map(\.role) == [.input])
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
                    "BatteryPower": 12_000,
                    "SystemPowerIn": 52_000,
                    "SystemLoad": 8_000,
                    "SystemVoltageIn": 18_740,
                    "SystemCurrentIn": 4_187
                ]
            ],
            adapterDetails: [:],
            smcPower: SMCPowerSnapshot(batteryPowerW: -9.8, externalPowerW: 51.2, systemPowerW: 7.4),
            environment: makeEnvironment()
        ).snapshot()

        #expect(snapshot.batteryPowerW == -9.8)
        #expect(snapshot.batteryPowerSource == .directTelemetry)
        #expect(snapshot.powerMeasurementSetSource == .smc)
        #expect(snapshot.adapterInputPowerW == 51.2)
        #expect(snapshot.adapterVoltageV == 18.74)
        #expect(snapshot.adapterCurrentA == 4.187)
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
