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

struct DiagnosticItem: Identifiable, Equatable, Sendable {
    let id = UUID()
    let severity: DiagnosticSeverity
    let title: String
    let message: String
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
    let adapterDescription: String?
    let adapterMaxPowerW: Double?
    let adapterInputPowerW: Double?
    let adapterVoltageV: Double?
    let adapterCurrentA: Double?
    let systemLoadW: Double?
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
        adapterDescription: String?,
        adapterMaxPowerW: Double?,
        adapterInputPowerW: Double?,
        adapterVoltageV: Double?,
        adapterCurrentA: Double?,
        systemLoadW: Double?,
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
        self.adapterDescription = adapterDescription
        self.adapterMaxPowerW = adapterMaxPowerW
        self.adapterInputPowerW = adapterInputPowerW
        self.adapterVoltageV = adapterVoltageV
        self.adapterCurrentA = adapterCurrentA
        self.systemLoadW = systemLoadW
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
            adapterDescription: adapterDescription,
            adapterMaxPowerW: adapterMaxPowerW,
            adapterInputPowerW: adapterInputPowerW,
            adapterVoltageV: adapterVoltageV,
            adapterCurrentA: adapterCurrentA,
            systemLoadW: systemLoadW,
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalState: thermalState,
            serialNumber: serialNumber,
            frontmostAppBundleID: frontmostAppBundleID,
            frontmostAppName: frontmostAppName,
            chargingPolicyStatus: chargingPolicyStatus
        )
    }
}
