import Foundation
import IOKit.ps
import Testing
@testable import PowerLens

struct SystemAPIProbeTests {
    @Test
    func commandDetectionDoesNotTreatNormalLaunchAsAProbe() {
        #expect(
            SystemAPIProbeCommand.isRequested(
                arguments: ["PowerLens", "--system-api-probe", "--format", "json"]
            )
        )
        #expect(
            !SystemAPIProbeCommand.isRequested(arguments: ["PowerLens"])
        )
    }

    @Test
    func reportHasAStableSanitizedSchema() throws {
        let report = SystemAPIProbe.makeReport()
        let data = try JSONEncoder().encode(report)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let encodedText = try #require(String(data: data, encoding: .utf8))

        #expect(
            report.schemaVersion == SystemAPIProbeReport.currentSchemaVersion
        )
        #expect(report.host.architecture == "arm64")
        #expect(report.powerUI.methods.count == PowerUIRuntime.contracts.count)
        #expect(object["schemaVersion"] as? Int == 2)
        #expect(
            TelemetrySystemContract.IOPowerSourceKey.currentCapacity.rawValue
                == kIOPSCurrentCapacityKey
        )
        #expect(
            TelemetrySystemContract.IOPowerSourceKey.powerSourceState.rawValue
                == kIOPSPowerSourceStateKey
        )
        #expect(
            TelemetrySystemContract.IOPowerSourceKey.isCharging.rawValue
                == kIOPSIsChargingKey
        )
        #expect(
            TelemetrySystemContract.IOPowerSourceKey.isCharged.rawValue
                == kIOPSIsChargedKey
        )
        #expect(
            TelemetrySystemContract.IOPowerSourceKey.timeToEmpty.rawValue
                == kIOPSTimeToEmptyKey
        )
        #expect(
            TelemetrySystemContract.IOPowerSourceKey.timeToFullCharge.rawValue
                == kIOPSTimeToFullChargeKey
        )
        #expect(
            Set(report.ioPowerSources.keys.map(\.path))
                == Set(
                    TelemetrySystemContract.ioPowerSourceKeyPaths.map(\.path)
                )
        )
        #expect(
            Set(report.externalPowerAdapter.keys.map(\.path))
                == Set(
                    TelemetrySystemContract.externalPowerAdapterKeyPaths.map(
                        \.path
                    )
                )
        )
        #expect(
            Set(report.appleSmartBattery.keys.map(\.path))
                == Set(
                    TelemetrySystemContract.appleSmartBatteryKeyPaths.map(
                        \.path
                    )
                )
        )
        #expect(
            Set(report.appleSMC.keys.map(\.key))
                == Set(
                    TelemetrySystemContract.AppleSMCKey.allCases.map(\.rawValue)
                )
        )
        #expect(!encodedText.contains("serialNumber"))
        #expect(!encodedText.contains("frontmostApp"))
        #expect(!encodedText.contains("batteryPowerW"))
        #expect(!encodedText.contains("adapterInputPowerW"))
    }

    @Test
    func reportSupportsCodableRoundTrip() throws {
        let report = SystemAPIProbe.makeReport()
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(
            SystemAPIProbeReport.self,
            from: data
        )

        #expect(decoded == report)
    }

    @Test
    func keyObservationsContainOnlyPresenceAndSanitizedTypes() throws {
        let privateSerial = "private-hardware-identifier"
        let observations = SystemAPIProbe.keyObservations(
            dictionary: [
                TelemetrySystemContract.AppleSmartBatteryKey
                    .powerTelemetryData.rawValue: [
                        TelemetrySystemContract.PowerTelemetryKey
                            .batteryPower.rawValue: 12.5,
                    ],
                TelemetrySystemContract.AppleSmartBatteryKey.serial.rawValue:
                    privateSerial,
            ],
            keyPaths: TelemetrySystemContract.appleSmartBatteryKeyPaths
        )

        let telemetryPower = try #require(
            observations.first {
                $0.path == "PowerTelemetryData.BatteryPower"
            }
        )
        let missingVoltage = try #require(
            observations.first { $0.path == "Voltage" }
        )
        #expect(telemetryPower.state == .available)
        #expect(telemetryPower.observedType == "number")
        #expect(missingVoltage.state == .keyMissing)
        #expect(missingVoltage.observedType == nil)

        let encoded = try JSONEncoder().encode(observations)
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(!text.contains(privateSerial))
    }

    @Test
    func nestedKeysAreNotAttemptedWithoutTheirParentDictionary() throws {
        let path = TelemetrySystemKeyPath(
            parent: TelemetrySystemContract.AppleSmartBatteryKey
                .powerTelemetryData.rawValue,
            child: TelemetrySystemContract.PowerTelemetryKey
                .batteryPower.rawValue
        )

        let missingParent = try #require(
            SystemAPIProbe.keyObservations(
                dictionary: [:],
                keyPaths: [path]
            ).first
        )
        let wrongParentType = try #require(
            SystemAPIProbe.keyObservations(
                dictionary: [
                    TelemetrySystemContract.AppleSmartBatteryKey
                        .powerTelemetryData.rawValue: "not-a-dictionary",
                ],
                keyPaths: [path]
            ).first
        )

        #expect(missingParent.state == .notAttempted)
        #expect(wrongParentType.state == .notAttempted)
    }

    @Test
    func smcFloatContractRequiresBothTypeAndSize() {
        let expected = SMCDataType.float

        #expect(expected.typeName == "flt ")
        #expect(expected.dataSize == 4)
        #expect(expected.isCompatible(with: .float))
        #expect(
            !SMCDataType(typeName: "ui16", dataSize: 4)
                .isCompatible(with: expected)
        )
        #expect(
            !SMCDataType(typeName: "flt ", dataSize: 8)
                .isCompatible(with: expected)
        )
    }
}
