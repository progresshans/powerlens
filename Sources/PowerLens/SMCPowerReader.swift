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
}

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct DataType: Equatable {
    let type: FourCharCode
    let size: UInt32
}

private enum DataTypes {
    static let float = DataType(type: FourCharCode(fromStaticString: "flt "), size: 4)
}

private struct SMCKey {
    let code: FourCharCode
    let info: DataType

    static let batteryPower = Self(code: .init(fromStaticString: "SBAP"), info: DataTypes.float)
    static let externalPower = Self(code: .init(fromStaticString: "PDTR"), info: DataTypes.float)
    static let systemPower = Self(code: .init(fromStaticString: "PSTR"), info: DataTypes.float)
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
        var inputStruct = SMCParamStruct()
        inputStruct.key = key.code
        inputStruct.keyInfo.dataSize = key.info.size
        inputStruct.data8 = SMCParamStruct.Selector.readKey.rawValue

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

        return outputStruct.bytes
    }
}

private extension FourCharCode {
    init(fromStaticString str: StaticString) {
        precondition(str.utf8CodeUnitCount == 4)

        self = str.withUTF8Buffer { buffer in
            let byte0 = UInt32(buffer[0]) << 24
            let byte1 = UInt32(buffer[1]) << 16
            let byte2 = UInt32(buffer[2]) << 8
            let byte3 = UInt32(buffer[3])
            return byte0 | byte1 | byte2 | byte3
        }
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
