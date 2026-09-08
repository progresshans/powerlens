import Foundation

enum PowerSourceKind: String, Codable, Sendable {
    case ac
    case battery
    case offline
    case unknown
}

enum ChargerAdequacy: String, Codable, Sendable {
    case disconnected
    case ample
    case adequate
    case constrained
    case insufficient
    case unknown

    var title: String {
        switch self {
        case .disconnected: L10n.text("chargerAdequacy.disconnected")
        case .ample: L10n.text("chargerAdequacy.ample")
        case .adequate: L10n.text("chargerAdequacy.adequate")
        case .constrained: L10n.text("chargerAdequacy.constrained")
        case .insufficient: L10n.text("chargerAdequacy.insufficient")
        case .unknown: L10n.text("chargerAdequacy.unknown")
        }
    }
}

enum ExternalPowerState: String, Codable, Sendable {
    case onBattery
    case charging
    case holding
    case connected

    var menuBarSymbolName: String {
        switch self {
        case .onBattery:
            "battery.75"
        case .charging:
            "bolt.fill"
        case .holding:
            "pause.circle.fill"
        case .connected:
            "powerplug.fill"
        }
    }
}

enum DiagnosticSeverity: String, Codable, Sendable {
    case info
    case caution
    case warning
}

enum DiagnosticKind: Hashable, Sendable {
    case powerDeliveryShortfall
    case temperatureHigh
    case batteryHealthWear
    case lowPowerMode
    case managedCharging
    case healthy
    case other
}

enum BatteryPowerSource: String, Codable, Sendable {
    case directTelemetry = "direct_telemetry"
    case currentAndVoltage = "current_and_voltage"

    var isDerived: Bool {
        self == .currentAndVoltage
    }
}

enum PowerMeasurementSetSource: String, Codable, Sendable {
    case smc
    case powerTelemetry = "power_telemetry"
}

struct DiagnosticItem: Identifiable, Equatable, Sendable {
    let id = UUID()
    let kind: DiagnosticKind
    let severity: DiagnosticSeverity
    let title: String
    let message: String

    init(
        kind: DiagnosticKind = .other,
        severity: DiagnosticSeverity,
        title: String,
        message: String
    ) {
        self.kind = kind
        self.severity = severity
        self.title = title
        self.message = message
    }
}

struct TelemetrySnapshot: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let batteryLevel: Double?
    let powerSource: PowerSourceKind
    let isCharging: Bool
    let isCharged: Bool
    let externalConnected: Bool
    let timeToEmptyMinutes: Int?
    let timeToFullMinutes: Int?
    let designCapacityMah: Int?
    let fullChargeCapacityMah: Int?
    let nominalCapacityMah: Int?
    let cycleCount: Int?
    let designCycleCount: Int?
    let batteryHealthText: String?
    let batteryHealthCondition: String?
    let batteryTemperatureC: Double?
    let batteryVoltageV: Double?
    let batteryCurrentA: Double?
    let batteryPowerW: Double?
    /// Describes how `batteryPowerW` was obtained without removing the value
    /// from consumers that cannot derive it independently.
    ///
    /// This remains optional so older JSON exports and history rows continue
    /// to decode as legacy snapshots with unknown provenance.
    let batteryPowerSource: BatteryPowerSource?
    let adapterDescription: String?
    let adapterMaxPowerW: Double?
    let adapterInputPowerW: Double?
    let adapterVoltageV: Double?
    let adapterCurrentA: Double?
    let systemLoadW: Double?
    /// Identifies when battery, input, and system power were selected together
    /// from one provider. A nil value means the readings are incomplete, mixed,
    /// or loaded from history without source provenance.
    let powerMeasurementSetSource: PowerMeasurementSetSource?
    let lowPowerModeEnabled: Bool
    let thermalState: String
    let serialNumber: String?
    let frontmostAppBundleID: String?
    let frontmostAppName: String?
    /// A live, read-only observation of the charging policy macOS is applying.
    ///
    /// This value is intentionally optional so snapshots decoded from older
    /// exports and snapshots loaded from the history database remain valid.
    /// PowerLens strips it before persistence because the first version of this
    /// feature is presentation-only.
    let chargingPolicyStatus: ObservedChargingPolicyStatus?

    var batteryPowerIsDerived: Bool {
        batteryPowerSource?.isDerived == true
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        batteryLevel: Double?,
        powerSource: PowerSourceKind,
        isCharging: Bool,
        isCharged: Bool,
        externalConnected: Bool,
        timeToEmptyMinutes: Int?,
        timeToFullMinutes: Int?,
        designCapacityMah: Int?,
        fullChargeCapacityMah: Int?,
        nominalCapacityMah: Int?,
        cycleCount: Int?,
        designCycleCount: Int?,
        batteryHealthText: String?,
        batteryHealthCondition: String?,
        batteryTemperatureC: Double?,
        batteryVoltageV: Double?,
        batteryCurrentA: Double?,
        batteryPowerW: Double?,
        batteryPowerSource: BatteryPowerSource? = nil,
        adapterDescription: String?,
        adapterMaxPowerW: Double?,
        adapterInputPowerW: Double?,
        adapterVoltageV: Double?,
        adapterCurrentA: Double?,
        systemLoadW: Double?,
        powerMeasurementSetSource: PowerMeasurementSetSource? = nil,
        lowPowerModeEnabled: Bool,
        thermalState: String,
        serialNumber: String?,
        frontmostAppBundleID: String? = nil,
        frontmostAppName: String?,
        chargingPolicyStatus: ObservedChargingPolicyStatus? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.batteryLevel = batteryLevel
        self.powerSource = powerSource
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.externalConnected = externalConnected
        self.timeToEmptyMinutes = timeToEmptyMinutes
        self.timeToFullMinutes = timeToFullMinutes
        self.designCapacityMah = designCapacityMah
        self.fullChargeCapacityMah = fullChargeCapacityMah
        self.nominalCapacityMah = nominalCapacityMah
        self.cycleCount = cycleCount
        self.designCycleCount = designCycleCount
        self.batteryHealthText = batteryHealthText
        self.batteryHealthCondition = batteryHealthCondition
        self.batteryTemperatureC = batteryTemperatureC
        self.batteryVoltageV = batteryVoltageV
        self.batteryCurrentA = batteryCurrentA
        self.batteryPowerW = batteryPowerW
        self.batteryPowerSource = batteryPowerSource
        self.adapterDescription = adapterDescription
        self.adapterMaxPowerW = adapterMaxPowerW
        self.adapterInputPowerW = adapterInputPowerW
        self.adapterVoltageV = adapterVoltageV
        self.adapterCurrentA = adapterCurrentA
        self.systemLoadW = systemLoadW
        self.powerMeasurementSetSource = powerMeasurementSetSource
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.thermalState = thermalState
        self.serialNumber = serialNumber
        self.frontmostAppBundleID = frontmostAppBundleID
        self.frontmostAppName = frontmostAppName
        self.chargingPolicyStatus = chargingPolicyStatus
    }

    func withChargingPolicyStatus(
        _ chargingPolicyStatus: ObservedChargingPolicyStatus?
    ) -> TelemetrySnapshot {
        TelemetrySnapshot(
            id: id,
            timestamp: timestamp,
            batteryLevel: batteryLevel,
            powerSource: powerSource,
            isCharging: isCharging,
            isCharged: isCharged,
            externalConnected: externalConnected,
            timeToEmptyMinutes: timeToEmptyMinutes,
            timeToFullMinutes: timeToFullMinutes,
            designCapacityMah: designCapacityMah,
            fullChargeCapacityMah: fullChargeCapacityMah,
            nominalCapacityMah: nominalCapacityMah,
            cycleCount: cycleCount,
            designCycleCount: designCycleCount,
            batteryHealthText: batteryHealthText,
            batteryHealthCondition: batteryHealthCondition,
            batteryTemperatureC: batteryTemperatureC,
            batteryVoltageV: batteryVoltageV,
            batteryCurrentA: batteryCurrentA,
            batteryPowerW: batteryPowerW,
            batteryPowerSource: batteryPowerSource,
            adapterDescription: adapterDescription,
            adapterMaxPowerW: adapterMaxPowerW,
            adapterInputPowerW: adapterInputPowerW,
            adapterVoltageV: adapterVoltageV,
            adapterCurrentA: adapterCurrentA,
            systemLoadW: systemLoadW,
            powerMeasurementSetSource: powerMeasurementSetSource,
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalState: thermalState,
            serialNumber: serialNumber,
            frontmostAppBundleID: frontmostAppBundleID,
            frontmostAppName: frontmostAppName,
            chargingPolicyStatus: chargingPolicyStatus
        )
    }
}
