import AppKit
import Foundation

/// The macOS energy mode for the current power source.
///
/// Macs without High Power Mode only report Low Power Mode on or off; Macs
/// that support High Power Mode expose `powermode` in `pmset -g`
/// (0 automatic, 1 low power, 2 high power).
enum EnergyMode: Equatable, Sendable {
    case automatic
    case lowPower
    case highPower
    /// Low Power Mode is off on a Mac without High Power Mode.
    case standard

    var supportsHighPower: Bool {
        switch self {
        case .automatic, .highPower: true
        case .lowPower, .standard: false
        }
    }

    var rowTitle: String {
        switch self {
        case .standard, .lowPower:
            L10n.text("energyMode.lowPower.title")
        case .automatic, .highPower:
            L10n.text("energyMode.title")
        }
    }

    var valueText: String {
        switch self {
        case .standard: L10n.text("common.off")
        case .lowPower: L10n.text("common.on")
        case .automatic: L10n.text("energyMode.automatic")
        case .highPower: L10n.text("energyMode.highPower")
        }
    }
}

enum EnergyModeReader {
    /// Parses `pmset -g` output. `lowPowerFallback` comes from
    /// `ProcessInfo.isLowPowerModeEnabled` for Macs without `powermode`.
    static func mode(pmsetOutput: String?, lowPowerFallback: Bool) -> EnergyMode {
        guard let pmsetOutput else {
            return lowPowerFallback ? .lowPower : .standard
        }

        for line in pmsetOutput.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0] == "powermode", let value = Int(fields[1]) else {
                continue
            }
            switch value {
            case 1: return .lowPower
            case 2: return .highPower
            default: return lowPowerFallback ? .lowPower : .automatic
            }
        }

        return lowPowerFallback ? .lowPower : .standard
    }

    /// Reads the current settings without elevated privileges.
    static func readPmset() async -> String? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-g"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }.value
    }
}

enum EnergyModeSettings {
    @MainActor
    static func open() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Battery-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.battery",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
