import Foundation
import IOKit

struct SMCPowerSnapshot {
    let batteryPowerW: Double?
    let externalPowerW: Double?
    let systemPowerW: Double?
}

protocol SMCPowerSnapshotReading {
    func readSnapshot() throws -> SMCPowerSnapshot
}

struct SMCPowerReader: SMCPowerSnapshotReading {
    func readSnapshot() throws -> SMCPowerSnapshot {
        let connection = try SMCKit.openConnection()
        defer { _ = SMCKit.close(connection) }

        let batteryPower = try readFloat(connection: connection, key: .batteryPower)
        let externalPower = try readFloat(connection: connection, key: .externalPower)
        let systemPower = try readFloat(connection: connection, key: .systemPower)

        return SMCPowerSnapshot(
            batteryPowerW: sanitize(power: batteryPower),
            externalPowerW: sanitize(power: externalPower),
            systemPowerW: sanitize(power: systemPower)
        )
    }

    private func readFloat(connection: io_connect_t, key: SMCKey) throws -> Double {
        let raw = try SMCKit.readData(connection: connection, key: key)
        return Double(Float(fromBytes: (raw.0, raw.1, raw.2, raw.3)))
    }

    private func sanitize(power: Double) -> Double {
        guard power.isFinite else {
            return 0
        }

        if abs(power) < 0.01 {
            return 0
        }

        return power
    }

    static func systemAPIProbeReport() -> SMCProbeReport {
        let connection: io_connect_t
        do {
            connection = try SMCKit.openConnection()
        } catch SMCReadError.driverNotFound {
            return SMCProbeReport(
                serviceAvailable: false,
                connectionState: .unavailable,
                keys: probeKeys(state: .notAttempted)
            )
        } catch {
            return SMCProbeReport(
                serviceAvailable: true,
                connectionState: .accessFailed,
                keys: probeKeys(state: .notAttempted)
            )
        }
        defer {
            _ = SMCKit.close(connection)
        }

        let keys: [(String, SMCKey)] = [
            (
                TelemetrySystemContract.AppleSMCKey.batteryPower.rawValue,
                .batteryPower
            ),
            (
                TelemetrySystemContract.AppleSMCKey.externalPower.rawValue,
                .externalPower
            ),
            (
                TelemetrySystemContract.AppleSMCKey.systemPower.rawValue,
                .systemPower
            ),
        ]
        return SMCProbeReport(
            serviceAvailable: true,
            connectionState: .available,
            keys: keys.map { name, key in
                do {
                    let actualInfo = try SMCKit.readKeyInfo(
                        connection: connection,
                        key: key
                    )
                    guard actualInfo.isCompatible(with: key.info) else {
                        return SMCKeyProbeReport(
                            key: name,
                            state: .typeMismatch,
                            observedDataType: actualInfo.typeName,
                            observedDataSize: actualInfo.dataSize
                        )
                    }
                    do {
                        _ = try SMCKit.readData(
                            connection: connection,
                            key: key,
                            validatedInfo: actualInfo
                        )
                        return SMCKeyProbeReport(
                            key: name,
                            state: .available,
                            observedDataType: actualInfo.typeName,
                            observedDataSize: actualInfo.dataSize
                        )
                    } catch SMCReadError.keyNotFound {
                        return SMCKeyProbeReport(
                            key: name,
                            state: .keyMissing,
                            observedDataType: nil,
                            observedDataSize: nil
                        )
                    } catch {
                        return SMCKeyProbeReport(
                            key: name,
                            state: .readFailed,
                            observedDataType: actualInfo.typeName,
                            observedDataSize: actualInfo.dataSize
                        )
                    }
                } catch SMCReadError.keyNotFound {
                    return SMCKeyProbeReport(
                        key: name,
                        state: .keyMissing,
                        observedDataType: nil,
                        observedDataSize: nil
                    )
                } catch {
                    return SMCKeyProbeReport(
                        key: name,
                        state: .readFailed,
                        observedDataType: nil,
                        observedDataSize: nil
                    )
                }
            }
        )
    }

    private static func probeKeys(
        state: SystemAPIProbeAccessState
    ) -> [SMCKeyProbeReport] {
        TelemetrySystemContract.AppleSMCKey.allCases.map {
            SMCKeyProbeReport(
                key: $0.rawValue,
                state: state,
                observedDataType: nil,
                observedDataSize: nil
            )
        }
    }
}

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

struct SMCDataType: Equatable, Sendable {
    let type: FourCharCode
    let size: UInt32

    init(typeName: String, dataSize: Int) {
        precondition(dataSize >= 0 && dataSize <= Int(UInt32.max))
        type = FourCharCode(fourCharacterString: typeName)
        size = UInt32(dataSize)
    }

    fileprivate init(type: FourCharCode, size: UInt32) {
        self.type = type
        self.size = size
    }

    var typeName: String {
        type.fourCharacterString
    }

    var dataSize: Int {
        Int(size)
    }

    func isCompatible(with expected: SMCDataType) -> Bool {
        self == expected
    }

    static let float = SMCDataType(
        typeName: TelemetrySystemContract.smcFloatDataType,
        dataSize: TelemetrySystemContract.smcFloatDataSize
    )
}

private struct SMCKey {
    let code: FourCharCode
    let info: SMCDataType

    static let batteryPower = Self(
        code: .init(
            fourCharacterString:
                TelemetrySystemContract.AppleSMCKey.batteryPower.rawValue
        ),
        info: .float
    )
    static let externalPower = Self(
        code: .init(
            fourCharacterString:
                TelemetrySystemContract.AppleSMCKey.externalPower.rawValue
        ),
        info: .float
    )
    static let systemPower = Self(
        code: .init(
            fourCharacterString:
                TelemetrySystemContract.AppleSMCKey.systemPower.rawValue
        ),
        info: .float
    )
}

private struct SMCParamStruct {
    enum Selector: UInt8 {
        case handleYPCEvent = 2
        case readKey = 5
        case getKeyInfo = 9
    }

    enum Result: UInt8 {
        case success = 0
        case keyNotFound = 132
    }

    struct SMCVersion {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }

    struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

private enum SMCReadError: Error {
    case driverNotFound
    case failedToOpen
    case keyNotFound
    case typeMismatch
    case readFailed(kern_return_t)
}

private enum SMCKit {
    static func openConnection() throws -> io_connect_t {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            throw SMCReadError.driverNotFound
        }

        var connection: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)

        guard result == kIOReturnSuccess else {
            throw SMCReadError.failedToOpen
        }

        return connection
    }

    @discardableResult
    static func close(_ connection: io_connect_t) -> Bool {
        guard connection != 0 else {
            return true
        }

        let result = IOServiceClose(connection)
        return result == kIOReturnSuccess
    }

    static func readData(connection: io_connect_t, key: SMCKey) throws -> SMCBytes {
        let actualInfo = try readKeyInfo(connection: connection, key: key)
        return try readData(
            connection: connection,
            key: key,
            validatedInfo: actualInfo
        )
    }

    static func readKeyInfo(
        connection: io_connect_t,
        key: SMCKey
    ) throws -> SMCDataType {
        var inputStruct = SMCParamStruct()
        inputStruct.key = key.code
        inputStruct.data8 = SMCParamStruct.Selector.getKeyInfo.rawValue

        let outputStruct = try call(
            connection: connection,
            inputStruct: &inputStruct
        )
        return SMCDataType(
            type: outputStruct.keyInfo.dataType,
            size: outputStruct.keyInfo.dataSize
        )
    }

    static func readData(
        connection: io_connect_t,
        key: SMCKey,
        validatedInfo: SMCDataType
    ) throws -> SMCBytes {
        guard validatedInfo.isCompatible(with: key.info) else {
            throw SMCReadError.typeMismatch
        }

        var inputStruct = SMCParamStruct()
        inputStruct.key = key.code
        inputStruct.keyInfo.dataSize = validatedInfo.size
        inputStruct.data8 = SMCParamStruct.Selector.readKey.rawValue

        return try call(
            connection: connection,
            inputStruct: &inputStruct
        ).bytes
    }

    private static func call(
        connection: io_connect_t,
        inputStruct: inout SMCParamStruct
    ) throws -> SMCParamStruct {
        var outputStruct = SMCParamStruct()
        let inputStructSize = MemoryLayout<SMCParamStruct>.stride
        var outputStructSize = MemoryLayout<SMCParamStruct>.stride

        let result = IOConnectCallStructMethod(
            connection,
            UInt32(SMCParamStruct.Selector.handleYPCEvent.rawValue),
            &inputStruct,
            inputStructSize,
            &outputStruct,
            &outputStructSize
        )

        guard result == kIOReturnSuccess else {
            throw SMCReadError.readFailed(result)
        }

        guard outputStruct.result == SMCParamStruct.Result.success.rawValue else {
            if outputStruct.result == SMCParamStruct.Result.keyNotFound.rawValue {
                throw SMCReadError.keyNotFound
            }
            throw SMCReadError.readFailed(result)
        }

        return outputStruct
    }
}

private extension FourCharCode {
    init(fourCharacterString string: String) {
        let bytes = Array(string.utf8)
        precondition(bytes.count == 4)
        self = UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
    }

    var fourCharacterString: String {
        let bytes = [
            UInt8((self >> 24) & 0xff),
            UInt8((self >> 16) & 0xff),
            UInt8((self >> 8) & 0xff),
            UInt8(self & 0xff),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }
}

private extension Float {
    init(fromBytes bytes: (UInt8, UInt8, UInt8, UInt8)) {
        let bitPattern = UInt32(bytes.0)
            | UInt32(bytes.1) << 8
            | UInt32(bytes.2) << 16
            | UInt32(bytes.3) << 24
        self = Float(bitPattern: bitPattern)
    }
}
