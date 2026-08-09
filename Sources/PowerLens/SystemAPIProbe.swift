import Darwin
import Foundation
import IOKit
import IOKit.ps
import ObjectiveC

enum SystemAPIProbeContractState: String, Codable, Sendable {
    case compatible
    case missing
    case incompatible
    case notInspected
}

enum SystemAPIProbeAccessState: String, Codable, Sendable {
    case available
    case unavailable
    case notAttempted
    case keyMissing
    case accessFailed
    case readFailed
    case typeMismatch
}

enum SystemAPIProbeKeyState: String, Codable, Sendable {
    case available
    case keyMissing
    case notAttempted
}

struct SystemAPIProbeHostReport: Codable, Equatable, Sendable {
    let operatingSystemVersion: String
    let operatingSystemBuild: String
    let architecture: String
}

struct SystemAPIProbeAppReport: Codable, Equatable, Sendable {
    let version: String
    let build: String
    let minimumMacOSVersion: String
}

struct PowerUIProbeMethodReport: Codable, Equatable, Sendable {
    let selector: String
    let dispatch: ObjectiveCMethodDispatch
    let expectedReturnTypes: [String]
    let expectedArgumentTypes: [String]
    let state: SystemAPIProbeContractState
    let actualTypeEncoding: String?
}

struct PowerUIProbeReport: Codable, Equatable, Sendable {
    let frameworkLoaded: Bool
    let clientClassFound: Bool?
    let methods: [PowerUIProbeMethodReport]
    let runtimeObservation: SystemCompatibilityDiagnostic
}

struct SystemAPIProbeKeyObservation: Codable, Equatable, Sendable {
    let path: String
    let state: SystemAPIProbeKeyState
    let observedType: String?
}

struct IOPowerSourcesProbeReport: Codable, Equatable, Sendable {
    let infoAvailable: Bool
    let sourceCount: Int
    let firstDescriptionAvailable: Bool
    let keys: [SystemAPIProbeKeyObservation]
}

struct IOAdapterProbeReport: Codable, Equatable, Sendable {
    let dictionaryAvailable: Bool
    let keys: [SystemAPIProbeKeyObservation]
}

struct AppleSmartBatteryProbeReport: Codable, Equatable, Sendable {
    let serviceAvailable: Bool
    let propertiesReadable: Bool
    let keys: [SystemAPIProbeKeyObservation]
}

struct SMCKeyProbeReport: Codable, Equatable, Sendable {
    let key: String
    let state: SystemAPIProbeAccessState
    let observedDataType: String?
    let observedDataSize: Int?
}

struct SMCProbeReport: Codable, Equatable, Sendable {
    let serviceAvailable: Bool
    let connectionState: SystemAPIProbeAccessState
    let keys: [SMCKeyProbeReport]
}

struct SystemAPIProbeReport: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let host: SystemAPIProbeHostReport
    let app: SystemAPIProbeAppReport
    let powerUI: PowerUIProbeReport
    let ioPowerSources: IOPowerSourcesProbeReport
    let externalPowerAdapter: IOAdapterProbeReport
    let appleSmartBattery: AppleSmartBatteryProbeReport
    let appleSMC: SMCProbeReport
}

enum SystemAPIProbe {
    static func makeReport(bundle: Bundle = .main) -> SystemAPIProbeReport {
        SystemAPIProbeReport(
            schemaVersion: SystemAPIProbeReport.currentSchemaVersion,
            host: hostReport(),
            app: appReport(bundle: bundle),
            powerUI: powerUIReport(),
            ioPowerSources: ioPowerSourcesReport(),
            externalPowerAdapter: adapterReport(),
            appleSmartBattery: smartBatteryReport(),
            appleSMC: SMCPowerReader.systemAPIProbeReport()
        )
    }

    private static func hostReport() -> SystemAPIProbeHostReport {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SystemAPIProbeHostReport(
            operatingSystemVersion:
                "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            operatingSystemBuild: systemControlString("kern.osversion")
                ?? "unknown",
            architecture: architecture
        )
    }

    private static func appReport(bundle: Bundle) -> SystemAPIProbeAppReport {
        SystemAPIProbeAppReport(
            version: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            build: bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown",
            minimumMacOSVersion: bundle.object(
                forInfoDictionaryKey: "LSMinimumSystemVersion"
            ) as? String ?? "unknown"
        )
    }

    private static func powerUIReport() -> PowerUIProbeReport {
        let runtimeObservation = PowerUIChargingPolicyReader()
            .readChargingPolicyObservation().diagnostic
        guard let frameworkHandle = dlopen(
            PowerUIRuntime.frameworkPath,
            RTLD_LAZY | RTLD_LOCAL
        ) else {
            return PowerUIProbeReport(
                frameworkLoaded: false,
                clientClassFound: nil,
                methods: PowerUIRuntime.contracts.map {
                    methodReport(
                        contract: $0,
                        inspection: nil
                    )
                },
                runtimeObservation: runtimeObservation
            )
        }
        defer {
            dlclose(frameworkHandle)
        }

        guard let clientClass = NSClassFromString(
            PowerUIRuntime.clientClassName
        ) else {
            return PowerUIProbeReport(
                frameworkLoaded: true,
                clientClassFound: false,
                methods: PowerUIRuntime.contracts.map {
                    methodReport(
                        contract: $0,
                        inspection: nil
                    )
                },
                runtimeObservation: runtimeObservation
            )
        }

        return PowerUIProbeReport(
            frameworkLoaded: true,
            clientClassFound: true,
            methods: PowerUIRuntime.contracts.map { contract in
                methodReport(
                    contract: contract,
                    inspection: ObjectiveCMethodInspector.inspect(
                        on: clientClass,
                        contract: contract
                    )
                )
            },
            runtimeObservation: runtimeObservation
        )
    }

    private static func methodReport(
        contract: ObjectiveCMethodContract,
        inspection: ObjectiveCMethodContractInspection?
    ) -> PowerUIProbeMethodReport {
        let state: SystemAPIProbeContractState
        let actualTypeEncoding: String?
        switch inspection {
        case .none:
            state = .notInspected
            actualTypeEncoding = nil
        case .missing:
            state = .missing
            actualTypeEncoding = nil
        case .compatible(let actual):
            state = .compatible
            actualTypeEncoding = actual
        case .incompatible(let actual):
            state = .incompatible
            actualTypeEncoding = actual
        }

        return PowerUIProbeMethodReport(
            selector: contract.selectorName,
            dispatch: contract.dispatch,
            expectedReturnTypes: contract.allowedReturnTypes,
            expectedArgumentTypes: contract.argumentTypes,
            state: state,
            actualTypeEncoding: actualTypeEncoding
        )
    }

    private static func ioPowerSourcesReport() -> IOPowerSourcesProbeReport {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue()
                as? [CFTypeRef]
        else {
            return IOPowerSourcesProbeReport(
                infoAvailable: false,
                sourceCount: 0,
                firstDescriptionAvailable: false,
                keys: keyObservations(
                    dictionary: nil,
                    keyPaths: TelemetrySystemContract.ioPowerSourceKeyPaths
                )
            )
        }

        guard let source = list.first,
              let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any]
        else {
            return IOPowerSourcesProbeReport(
                infoAvailable: true,
                sourceCount: list.count,
                firstDescriptionAvailable: false,
                keys: keyObservations(
                    dictionary: nil,
                    keyPaths: TelemetrySystemContract.ioPowerSourceKeyPaths
                )
            )
        }

        return IOPowerSourcesProbeReport(
            infoAvailable: true,
            sourceCount: list.count,
            firstDescriptionAvailable: true,
            keys: keyObservations(
                dictionary: description,
                keyPaths: TelemetrySystemContract.ioPowerSourceKeyPaths
            )
        )
    }

    private static func adapterReport() -> IOAdapterProbeReport {
        guard let adapter = IOPSCopyExternalPowerAdapterDetails()?
            .takeRetainedValue() as? [String: Any]
        else {
            return IOAdapterProbeReport(
                dictionaryAvailable: false,
                keys: keyObservations(
                    dictionary: nil,
                    keyPaths:
                        TelemetrySystemContract.externalPowerAdapterKeyPaths
                )
            )
        }

        return IOAdapterProbeReport(
            dictionaryAvailable: true,
            keys: keyObservations(
                dictionary: adapter,
                keyPaths:
                    TelemetrySystemContract.externalPowerAdapterKeyPaths
            )
        )
    }

    private static func smartBatteryReport() -> AppleSmartBatteryProbeReport {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else {
            return AppleSmartBatteryProbeReport(
                serviceAvailable: false,
                propertiesReadable: false,
                keys: keyObservations(
                    dictionary: nil,
                    keyPaths:
                        TelemetrySystemContract.appleSmartBatteryKeyPaths
                )
            )
        }
        defer {
            IOObjectRelease(service)
        }

        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(
            service,
            &properties,
            kCFAllocatorDefault,
            0
        )
        guard result == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue()
                as? [String: Any]
        else {
            return AppleSmartBatteryProbeReport(
                serviceAvailable: true,
                propertiesReadable: false,
                keys: keyObservations(
                    dictionary: nil,
                    keyPaths:
                        TelemetrySystemContract.appleSmartBatteryKeyPaths
                )
            )
        }

        return AppleSmartBatteryProbeReport(
            serviceAvailable: true,
            propertiesReadable: true,
            keys: keyObservations(
                dictionary: dictionary,
                keyPaths: TelemetrySystemContract.appleSmartBatteryKeyPaths
            )
        )
    }

    static func keyObservations(
        dictionary: [String: Any]?,
        keyPaths: [TelemetrySystemKeyPath]
    ) -> [SystemAPIProbeKeyObservation] {
        keyPaths.map { keyPath in
            guard let dictionary else {
                return SystemAPIProbeKeyObservation(
                    path: keyPath.path,
                    state: .notAttempted,
                    observedType: nil
                )
            }

            var container = dictionary
            for (index, component) in keyPath.components.enumerated() {
                let isLeaf = index == keyPath.components.count - 1
                guard let value = container[component] else {
                    return SystemAPIProbeKeyObservation(
                        path: keyPath.path,
                        state: isLeaf ? .keyMissing : .notAttempted,
                        observedType: nil
                    )
                }
                if isLeaf {
                    return SystemAPIProbeKeyObservation(
                        path: keyPath.path,
                        state: .available,
                        observedType: sanitizedTypeName(value)
                    )
                }
                guard let nested = value as? [String: Any] else {
                    return SystemAPIProbeKeyObservation(
                        path: keyPath.path,
                        state: .notAttempted,
                        observedType: nil
                    )
                }
                container = nested
            }

            preconditionFailure("Telemetry key paths must not be empty")
        }
    }

    private static func sanitizedTypeName(_ value: Any) -> String {
        switch value {
        case is String:
            "string"
        case let number as NSNumber:
            CFGetTypeID(number) == CFBooleanGetTypeID()
                ? "boolean"
                : "number"
        case is [String: Any]:
            "dictionary"
        case is [Any]:
            "array"
        case is Data:
            "data"
        default:
            "other"
        }
    }

    private static func systemControlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0,
              size > 1
        else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map {
            UInt8(bitPattern: $0)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

enum SystemAPIProbeCommand {
    static func isRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains("--system-api-probe")
    }

    static func run(arguments: [String] = CommandLine.arguments) -> Int32 {
        guard requestedFormat(arguments: arguments) == "json" else {
            fputs(
                "PowerLens system API probe supports only --format json\n",
                stderr
            )
            return 64
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(SystemAPIProbe.makeReport())
            try FileHandle.standardOutput.write(contentsOf: data)
            try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
            return 0
        } catch {
            fputs("PowerLens system API probe could not write its report\n", stderr)
            return 70
        }
    }

    private static func requestedFormat(arguments: [String]) -> String? {
        if let inline = arguments.first(where: { $0.hasPrefix("--format=") }) {
            return String(inline.dropFirst("--format=".count))
        }

        guard let index = arguments.firstIndex(of: "--format"),
              arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return arguments[index + 1]
    }
}
