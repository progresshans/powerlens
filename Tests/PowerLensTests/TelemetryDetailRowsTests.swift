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

    @Test
    func derivedBatteryPowerIsMarkedAsApproximate() {
        let snapshot = makeTelemetrySnapshot(
            batteryPowerW: 10.045,
            batteryPowerSource: .currentAndVoltage
        )
        let batteryPowerTitle = L10n.text("ui.detail.batteryPower")

        let value = TelemetryDetailRows.powerSnapshot(snapshot)
            .first { $0.0 == batteryPowerTitle }?
            .1

        #expect(
            value
                == L10n.tr(
                    "format.batteryPower.discharging",
                    "≈10.0W"
                )
        )
    }

    @Test
    func roundedZeroPreservesBatteryPowerProvenance() {
        let derivedSnapshot = makeTelemetrySnapshot(
            batteryPowerW: 0.04,
            batteryPowerSource: .currentAndVoltage
        )
        let directSnapshot = makeTelemetrySnapshot(
            batteryPowerW: 0.04,
            batteryPowerSource: .directTelemetry
        )
        let batteryPowerTitle = L10n.text("ui.detail.batteryPower")

        let derivedValue = TelemetryDetailRows.powerSnapshot(
            derivedSnapshot
        ).first { $0.0 == batteryPowerTitle }?.1
        let directValue = TelemetryDetailRows.powerSnapshot(
            directSnapshot
        ).first { $0.0 == batteryPowerTitle }?.1

        #expect(derivedValue == "≈0.0W")
        #expect(directValue == "0.0W")
    }
}
