import Foundation

struct CompatibleTelemetryReader: TelemetrySnapshotReader {
    private let platform: any TelemetryPlatformAccessing

    init(platform: any TelemetryPlatformAccessing = SystemTelemetryPlatformAccess()) {
        self.platform = platform
    }

    func readSnapshot() throws -> TelemetrySnapshot {
        try CompatibleTelemetrySnapshotMapper(
            powerSourceInfo: platform.readPowerSourceDescription(),
            adapterDetails: platform.readAdapterDetails(),
            environment: platform.readEnvironment()
        ).snapshot()
    }
}

struct LivePrecisionTelemetryReader: TelemetrySnapshotReader {
    private let platform: any TelemetryPlatformAccessing
    private let smcPowerReader: any SMCPowerSnapshotReading

    init(
        platform: any TelemetryPlatformAccessing = SystemTelemetryPlatformAccess(),
        smcPowerReader: any SMCPowerSnapshotReading = SMCPowerReader()
    ) {
        self.platform = platform
        self.smcPowerReader = smcPowerReader
    }

    func readSnapshot() throws -> TelemetrySnapshot {
        try LivePrecisionTelemetrySnapshotMapper(
            powerSourceInfo: platform.readPowerSourceDescription(),
            batteryRegistry: platform.readBatteryRegistry(),
            adapterDetails: platform.readAdapterDetails(),
            smcPower: try? smcPowerReader.readSnapshot(),
            environment: platform.readEnvironment()
        ).snapshot()
    }
}
