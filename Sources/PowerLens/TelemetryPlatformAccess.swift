import AppKit
import Foundation
import IOKit
import IOKit.ps

struct FrontmostApplicationInfo: Equatable, Sendable {
    let bundleIdentifier: String?
    let localizedName: String?
}

struct TelemetryReadEnvironment {
    let lowPowerModeEnabled: Bool
    let thermalState: ProcessInfo.ThermalState
    let frontmostApplication: FrontmostApplicationInfo?
}

protocol TelemetryPlatformAccessing {
    func readPowerSourceDescription() -> [String: Any]
    func readAdapterDetails() -> [String: Any]
    func readBatteryRegistry() -> [String: Any]
    func readEnvironment() -> TelemetryReadEnvironment
}

struct SystemTelemetryPlatformAccess: TelemetryPlatformAccessing {
    func readPowerSourceDescription() -> [String: Any] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let source = list.first,
              let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
        else {
            return [:]
        }

        return description
    }

    func readAdapterDetails() -> [String: Any] {
        guard let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] else {
            return [:]
        }

        return adapter
    }

    func readBatteryRegistry() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            return [:]
        }

        defer {
            IOObjectRelease(service)
        }

        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else {
            return [:]
        }

        return dictionary
    }

    func readEnvironment() -> TelemetryReadEnvironment {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        return TelemetryReadEnvironment(
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState,
            frontmostApplication: FrontmostApplicationInfo(
                bundleIdentifier: frontmostApp?.bundleIdentifier,
                localizedName: frontmostApp?.localizedName
            )
        )
    }
}

enum TelemetryValueParser {
    static func parsePowerSource(_ value: String?) -> PowerSourceKind {
        switch value {
        case kIOPMACPowerKey:
            .ac
        case kIOPMBatteryPowerKey:
            .battery
        case "Off Line":
            .offline
        default:
            .unknown
        }
    }

    static func inferredHealthText(from batteryRegistry: [String: Any]) -> String? {
        if intValue(batteryRegistry["PermanentFailureStatus"]) ?? 0 > 0 {
            return "Service Recommended"
        }

        if let design = intValue(batteryRegistry["DesignCapacity"]),
           let max = intValue(batteryRegistry["AppleRawMaxCapacity"]),
           design > 0 {
            let ratio = Double(max) / Double(design) * 100
            if ratio >= 85 {
                return "Normal"
            }
            return "Aged"
        }

        return nil
    }

    static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            "Nominal"
        case .fair:
            "Fair"
        case .serious:
            "Serious"
        case .critical:
            "Critical"
        @unknown default:
            "Unknown"
        }
    }

    static func sanitize(minutes: Int?) -> Int? {
        guard let minutes, minutes > 0, minutes < 10_000 else {
            return nil
        }
        return minutes
    }

    static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let value as Int:
            value
        case let value as Int32:
            Int(value)
        case let value as NSNumber:
            value.intValue
        case let value as Double:
            Int(value)
        default:
            nil
        }
    }

    static func doubleValue(_ any: Any?) -> Double? {
        switch any {
        case let value as Double:
            value
        case let value as Float:
            Double(value)
        case let value as Int:
            Double(value)
        case let value as Int32:
            Double(value)
        case let value as NSNumber:
            value.doubleValue
        default:
            nil
        }
    }

    static func boolValue(_ any: Any?) -> Bool? {
        switch any {
        case let value as Bool:
            value
        case let value as NSNumber:
            value.boolValue
        default:
            nil
        }
    }

    static func nonEmptyString(_ any: Any?) -> String? {
        guard let string = any as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return string
    }

    static func milliwattsValue(_ any: Any?) -> Double? {
        doubleValue(any).map { $0 / 1000 }
    }
}
