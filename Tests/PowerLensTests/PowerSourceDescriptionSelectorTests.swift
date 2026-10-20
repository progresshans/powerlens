import Foundation
import IOKit.ps
import Testing
@testable import PowerLens

struct PowerSourceDescriptionSelectorTests {
    @Test
    @MainActor
    func upsFirstDoesNotMakeCompatibleTelemetryDisagreeWithTheSourceMonitor() throws {
        let descriptions: [[String: Any]] = [
            [
                kIOPSTypeKey: kIOPSUPSType,
                kIOPSPowerSourceStateKey: kIOPMACPowerKey,
                kIOPSCurrentCapacityKey: 100,
            ],
            [
                kIOPSTypeKey: kIOPSInternalBatteryType,
                kIOPSPowerSourceStateKey: kIOPMBatteryPowerKey,
                kIOPSCurrentCapacityKey: 72,
            ],
        ]
        let description = try #require(
            PowerSourceDescriptionSelector.preferred(in: descriptions)
        )
        let snapshot = try CompatibleTelemetrySnapshotMapper(
            powerSourceInfo: description,
            adapterDetails: [:],
            environment: TelemetryReadEnvironment(
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                frontmostApplication: nil
            )
        ).snapshot()

        #expect(snapshot.batteryLevel == 72)
        #expect(snapshot.powerSource == .battery)
        #expect(!snapshot.externalConnected)
        #expect(
            snapshot.externalConnected
                == SystemPowerSourceStateReader.externalConnected(in: descriptions)
        )
    }

    @Test
    func missingInternalBatteryKeepsTheFirstSourceFallback() throws {
        let descriptions: [[String: Any]] = [
            [
                kIOPSTypeKey: kIOPSUPSType,
                kIOPSPowerSourceStateKey: kIOPMACPowerKey,
                kIOPSCurrentCapacityKey: 84,
            ],
            [
                kIOPSTypeKey: kIOPSUPSType,
                kIOPSPowerSourceStateKey: kIOPMBatteryPowerKey,
                kIOPSCurrentCapacityKey: 35,
            ],
        ]
        let description = try #require(
            PowerSourceDescriptionSelector.preferred(in: descriptions)
        )

        #expect(PowerSourceDescriptionSelector.internalBattery(in: descriptions) == nil)
        #expect(description[kIOPSCurrentCapacityKey] as? Int == 84)
        #expect(description[kIOPSPowerSourceStateKey] as? String == kIOPMACPowerKey)
    }

    @Test
    func noPowerSourcesRemainUnavailable() {
        #expect(PowerSourceDescriptionSelector.internalBattery(in: []) == nil)
        #expect(PowerSourceDescriptionSelector.preferred(in: []) == nil)
    }
}
