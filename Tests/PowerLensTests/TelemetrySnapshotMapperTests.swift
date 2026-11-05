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
        #expect(snapshot.primaryDisplayedPower?.watts == 10.0)
        #expect(snapshot.primaryDisplayedPower?.isApproximate == true)

        let flow = PowerFlowPresentationModel(snapshot: snapshot)
        #expect(flow.state == .discharging)
        #expect(flow.routes.first?.source.value == "10.0W")
        #expect(flow.routes.first?.target.value == "10.0W")
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

        // The battery measurement remains available, but neither a measured
        // system value nor a complete balance can anchor a flow diagram.
        let readings = PowerFlowReadings(snapshot: snapshot)
        #expect(readings.state == .charging)
        #expect(!readings.hasBalancedFlow)
        #expect(readings.systemPowerSource == .unavailable)
        #expect(readings.systemPower == nil)
        let flow = PowerFlowPresentationModel(snapshot: snapshot)
        #expect(flow.state == .unknown)
        #expect(flow.routes.count == 1)
        #expect(flow.routes.first?.source.value == L10n.text("common.none"))
        #expect(flow.routes.first?.target.value == L10n.text("common.none"))
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
        #expect(flow.routes.map(\.role) == [.input, .charge])
        #expect(flow.routes.first?.source.value == "82.7W")
        #expect(flow.routes.first?.target.value == "8.8W")
        #expect(flow.routes.last?.target.value == "73.9W")
        #expect(snapshot.adapterInputPowerW == 82.9)
        #expect(snapshot.systemLoadW == 8.8)
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
        #expect(flow.routes.first?.source.value == L10n.text("common.none"))
        #expect(flow.routes.first?.target.value == "8.8W")
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

        let flow = PowerFlowPresentationModel(snapshot: snapshot)
        #expect(flow.state == .charging)
        #expect(flow.routes.first?.source.value == "17.2W")
        #expect(flow.routes.first?.target.value == "7.4W")
        #expect(flow.routes.last?.target.value == "9.8W")
        #expect(snapshot.primaryDisplayedPower?.watts == 7.4)
    }

    /// macOS 27.2 dropped the top-level capacity and `Temperature` keys.
    @Test
    func livePrecisionMapperReadsMacOS27BatteryDataAndSMCTemperature() throws {
        let snapshot = try LivePrecisionTelemetrySnapshotMapper(
            powerSourceInfo: [
                kIOPSPowerSourceStateKey: kIOPMBatteryPowerKey,
                kIOPSCurrentCapacityKey: 84
            ],
            batteryRegistry: [
                "ExternalConnected": false,
                "Voltage": 12_339,
                "Amperage": -1_084,
                "CycleCount": 122,
                "BatteryData": [
                    "DesignCapacity": 6_249,
                    "AppleRawMaxCapacity": 5_750,
                    "NominalChargeCapacity": 5_902
                ]
            ],
            adapterDetails: [:],
            smcPower: SMCPowerSnapshot(
                batteryPowerW: 13.4,
                externalPowerW: 0,
                systemPowerW: 13.4,
                batteryTemperatureC: 32
            ),
            environment: makeEnvironment()
        ).snapshot()

        #expect(snapshot.designCapacityMah == 6_249)
        #expect(snapshot.fullChargeCapacityMah == 5_750)
        #expect(snapshot.nominalCapacityMah == 5_902)
        #expect(snapshot.batteryHealthText == "Normal")
        #expect(snapshot.batteryTemperatureC == 32)
    }

    @Test
    func topLevelBatteryReadingsTakePrecedenceOverFallbacks() throws {
        let snapshot = try LivePrecisionTelemetrySnapshotMapper(
            powerSourceInfo: [
                kIOPSPowerSourceStateKey: kIOPMBatteryPowerKey,
                kIOPSCurrentCapacityKey: 84
            ],
            batteryRegistry: [
                "Voltage": 12_339,
                "Amperage": -1_084,
                "DesignCapacity": 6_249,
                "AppleRawMaxCapacity": 5_000,
                "Temperature": 3_050,
                "BatteryData": [
                    "DesignCapacity": 1,
                    "AppleRawMaxCapacity": 1
                ]
            ],
            adapterDetails: [:],
            smcPower: SMCPowerSnapshot(
                batteryPowerW: nil,
                externalPowerW: nil,
                systemPowerW: nil,
                batteryTemperatureC: 41
            ),
            environment: makeEnvironment()
        ).snapshot()

        #expect(snapshot.designCapacityMah == 6_249)
        #expect(snapshot.fullChargeCapacityMah == 5_000)
        #expect(snapshot.batteryHealthText == "Aged")
        #expect(snapshot.batteryTemperatureC == 30.5)
    }

    @Test
    func missingCapacitiesAndTemperatureStayUnknown() throws {
        let snapshot = try LivePrecisionTelemetrySnapshotMapper(
            powerSourceInfo: [
                kIOPSPowerSourceStateKey: kIOPMBatteryPowerKey,
                kIOPSCurrentCapacityKey: 84
            ],
            batteryRegistry: [
                "Voltage": 12_339,
                "Amperage": -1_084,
                "BatteryData": ["CurrentCapacity": 84]
            ],
            adapterDetails: [:],
            smcPower: nil,
            environment: makeEnvironment()
        ).snapshot()

        #expect(snapshot.designCapacityMah == nil)
        #expect(snapshot.fullChargeCapacityMah == nil)
        #expect(snapshot.batteryHealthText == nil)
        #expect(snapshot.batteryTemperatureC == nil)
    }

    @Test(arguments: [
        ([32.0, 32.0, 31.9], 32.0 as Double?),
        ([0, 31.2], 31.2),
        ([.nan, 150, -5, 30.4], 30.4),
        ([0, 0, 0], nil),
        ([], nil),
    ])
    func smcBatteryTemperatureUsesTheWarmestPlausibleSensor(readings: [Double], expected: Double?) {
        #expect(SMCPowerReader.batteryTemperature(from: readings) == expected)
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
