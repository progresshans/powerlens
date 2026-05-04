import Testing
@testable import PowerLens

struct TelemetryDetailRowsTests {
    @Test
    func batteryFlowUsesDirectionalBatteryPowerText() {
        let chargingSnapshot = makeTelemetrySnapshot(batteryPowerW: -46.4)
        let dischargingSnapshot = makeTelemetrySnapshot(
            powerSource: .battery,
            externalConnected: false,
            batteryPowerW: 9.1,
            adapterInputPowerW: 0,
            systemLoadW: 9.1
        )

        let chargingRows = TelemetryDetailRows.batteryFlow(chargingSnapshot)
        let dischargingRows = TelemetryDetailRows.batteryFlow(dischargingSnapshot)

        #expect(chargingRows.contains { _, value in
            value == L10n.tr("format.batteryPower.charging", "46.4W")
        })
        #expect(dischargingRows.contains { _, value in
            value == L10n.tr("format.batteryPower.discharging", "9.1W")
        })
    }

    @Test
    func powerSnapshotAndBatteryFlowUseSameBatteryPowerFormatter() {
        let snapshot = makeTelemetrySnapshot(batteryPowerW: -12.3)
        let powerRows = TelemetryDetailRows.powerSnapshot(snapshot)
        let batteryRows = TelemetryDetailRows.batteryFlow(snapshot)
        let batteryPowerTitle = L10n.text("ui.detail.batteryPower")

        #expect(powerRows.first { $0.0 == batteryPowerTitle }?.1 == batteryRows.first { $0.0 == batteryPowerTitle }?.1)
    }
}
