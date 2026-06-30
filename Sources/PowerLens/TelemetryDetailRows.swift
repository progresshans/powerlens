import Foundation

enum TelemetryDetailRows {
    static func batterySnapshot(_ snapshot: TelemetrySnapshot) -> [(String, String)] {
        [
            (L10n.text("ui.detail.designCapacity"), snapshot.designCapacityMah.map { "\($0) mAh" } ?? L10n.text("common.none")),
            (L10n.text("ui.detail.fullChargeCapacity"), snapshot.fullChargeCapacityMah.map { "\($0) mAh" } ?? L10n.text("common.none")),
            (L10n.text("ui.detail.macOSCapacity"), snapshot.nominalCapacityMah.map { "\($0) mAh" } ?? L10n.text("common.none")),
            (L10n.text("ui.metric.health"), snapshot.chargeHealthPercent.map(Formatters.percent) ?? L10n.text("common.none")),
            (L10n.text("ui.metric.cycles"), snapshot.cycleCount.map(String.init) ?? L10n.text("common.none")),
            (L10n.text("ui.metric.batteryTemp"), snapshot.batteryTemperatureC.map(Formatters.temperature) ?? L10n.text("common.none")),
        ]
    }

    static func powerSnapshot(_ snapshot: TelemetrySnapshot) -> [(String, String)] {
        [
            (L10n.text("ui.detail.inputVoltage"), snapshot.adapterVoltageV.map(Formatters.voltage) ?? L10n.text("common.none")),
            (L10n.text("ui.detail.inputCurrent"), snapshot.adapterCurrentA.map(Formatters.current) ?? L10n.text("common.none")),
            (L10n.text("ui.metric.powerIn"), snapshot.adapterInputPowerW.map(Formatters.power) ?? L10n.text("common.none")),
            (L10n.text("ui.detail.voltage"), snapshot.batteryVoltageV.map(Formatters.voltage) ?? L10n.text("common.none")),
            (L10n.text("ui.detail.current"), Formatters.batteryCurrentFlow(snapshot.batteryCurrentA)),
            (L10n.text("ui.detail.batteryPower"), Formatters.batteryPowerFlow(snapshot.batteryPowerW)),
            (L10n.text("ui.metric.systemLoad"), snapshot.systemLoadW.map(Formatters.power) ?? L10n.text("common.none")),
            (L10n.text("ui.detail.lowPowerMode"), snapshot.lowPowerModeEnabled ? L10n.text("common.on") : L10n.text("common.off")),
        ]
    }

    static func adapter(_ snapshot: TelemetrySnapshot) -> [(String, String)] {
        [
            (L10n.text("ui.detail.description"), snapshot.adapterDescription ?? L10n.text("common.none")),
            (L10n.text("ui.detail.maxPower"), snapshot.adapterMaxPowerW.map(Formatters.power) ?? L10n.text("common.none")),
            (L10n.text("ui.detail.inputVoltage"), snapshot.adapterVoltageV.map(Formatters.voltage) ?? L10n.text("common.none")),
            (L10n.text("ui.detail.inputCurrent"), snapshot.adapterCurrentA.map(Formatters.current) ?? L10n.text("common.none")),
        ]
    }

    static func system(_ snapshot: TelemetrySnapshot, lastRefreshAt: Date?) -> [(String, String)] {
        [
            (L10n.text("ui.detail.powerSource"), L10n.localizedPowerSource(snapshot.powerSource)),
            (L10n.text("ui.metric.load"), snapshot.systemLoadW.map(Formatters.power) ?? L10n.text("common.none")),
            (L10n.text("ui.detail.lowPowerMode"), snapshot.lowPowerModeEnabled ? L10n.text("common.on") : L10n.text("common.off")),
            (L10n.text("ui.detail.lastUpdate"), Formatters.lastUpdated(lastRefreshAt ?? snapshot.timestamp)),
        ]
    }

    static func batteryPack(_ snapshot: TelemetrySnapshot) -> [(String, String)] {
        [
            (L10n.text("ui.detail.designCapacity"), snapshot.designCapacityMah.map { "\($0) mAh" } ?? L10n.text("common.none")),
            (L10n.text("ui.detail.fullChargeCapacity"), snapshot.fullChargeCapacityMah.map { "\($0) mAh" } ?? L10n.text("common.none")),
            (L10n.text("ui.detail.macOSCapacity"), snapshot.nominalCapacityMah.map { "\($0) mAh" } ?? L10n.text("common.none")),
            (L10n.text("ui.detail.serial"), snapshot.serialNumber ?? L10n.text("common.none")),
        ]
    }

    static func batteryFlow(_ snapshot: TelemetrySnapshot) -> [(String, String)] {
        [
            (L10n.text("ui.detail.voltage"), snapshot.batteryVoltageV.map(Formatters.voltage) ?? L10n.text("common.none")),
            (L10n.text("ui.detail.current"), Formatters.batteryCurrentFlow(snapshot.batteryCurrentA)),
            (L10n.text("ui.detail.batteryPower"), Formatters.batteryPowerFlow(snapshot.batteryPowerW)),
            (L10n.text("ui.detail.timeToEmpty"), Formatters.minutes(snapshot.timeToEmptyMinutes)),
        ]
    }
}
