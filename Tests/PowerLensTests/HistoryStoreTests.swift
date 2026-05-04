import Foundation
import SQLite3
import Testing
@testable import PowerLens

struct HistoryStoreTests {
    @Test
    func reusesReferenceRowsForRepeatedSamples() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "reused-references")
        let store = HistoryStore(databaseURL: dbURL)

        let baseTime = Date(timeIntervalSince1970: 1_775_628_000)
        let first = makeSnapshot(timestamp: baseTime, systemLoadW: 22.3, batteryTemperatureC: 29.4)
        let second = makeSnapshot(timestamp: baseTime.addingTimeInterval(60), systemLoadW: 26.1, batteryTemperatureC: 30.2)

        await store.append(first)
        await store.append(second)

        #expect(try tableCount("batteries", dbURL: dbURL) == 1)
        #expect(try tableCount("battery_states", dbURL: dbURL) == 1)
        #expect(try tableCount("adapters", dbURL: dbURL) == 1)
        #expect(try tableCount("apps", dbURL: dbURL) == 1)
        #expect(try tableCount("telemetry_samples", dbURL: dbURL) == 2)

        let loaded = await store.loadRecent(since: baseTime.addingTimeInterval(-120))
        #expect(loaded.count == 2)
        #expect(loaded.last?.frontmostAppBundleID == "com.openai.codex")
        #expect(loaded.last?.designCapacityMah == 6249)
        #expect(loaded.last?.adapterDescription == "PD Charger")
    }

    @Test
    func createsNewBatteryStateOnlyWhenSlowStateChanges() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "battery-state-changes")
        let store = HistoryStore(databaseURL: dbURL)

        let baseTime = Date(timeIntervalSince1970: 1_775_628_300)
        let first = makeSnapshot(timestamp: baseTime, cycleCount: 74, fullChargeCapacityMah: 5637, nominalCapacityMah: 5874)
        let second = makeSnapshot(
            timestamp: baseTime.addingTimeInterval(60),
            cycleCount: 75,
            fullChargeCapacityMah: 5600,
            nominalCapacityMah: 5840
        )

        await store.append(first)
        await store.append(second)

        #expect(try tableCount("batteries", dbURL: dbURL) == 1)
        #expect(try tableCount("battery_states", dbURL: dbURL) == 2)
        #expect(try tableCount("telemetry_samples", dbURL: dbURL) == 2)

        let loaded = await store.loadRecent(since: baseTime.addingTimeInterval(-120))
        #expect(loaded.last?.cycleCount == 75)
        #expect(loaded.last?.fullChargeCapacityMah == 5600)
        #expect(loaded.last?.nominalCapacityMah == 5840)
    }
}

private func makeSnapshot(
    timestamp: Date,
    cycleCount: Int = 74,
    fullChargeCapacityMah: Int = 5637,
    nominalCapacityMah: Int = 5874,
    systemLoadW: Double = 22.36,
    batteryTemperatureC: Double = 29.5
) -> TelemetrySnapshot {
    TelemetrySnapshot(
        timestamp: timestamp,
        batteryLevel: 80,
        powerSource: .ac,
        isCharging: false,
        isCharged: false,
        externalConnected: true,
        timeToEmptyMinutes: nil,
        timeToFullMinutes: nil,
        designCapacityMah: 6249,
        fullChargeCapacityMah: fullChargeCapacityMah,
        nominalCapacityMah: nominalCapacityMah,
        cycleCount: cycleCount,
        designCycleCount: 1000,
        batteryHealthText: "Normal",
        batteryHealthCondition: nil,
        batteryTemperatureC: batteryTemperatureC,
        batteryVoltageV: 12.38,
        batteryCurrentA: 0.0,
        batteryPowerW: 0.0,
        adapterDescription: "PD Charger",
        adapterMaxPowerW: 97,
        adapterInputPowerW: 20.92,
        adapterVoltageV: 19.26,
        adapterCurrentA: 1.09,
        systemLoadW: systemLoadW,
        lowPowerModeEnabled: false,
        thermalState: "Nominal",
        serialNumber: "F5DH2H0043N00000EB",
        frontmostAppBundleID: "com.openai.codex",
        frontmostAppName: "Codex"
    )
}

private func makeTemporaryDatabaseURL(name: String) -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PowerLensTests", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("\(name)-\(UUID().uuidString).sqlite3")
}

private func tableCount(_ table: String, dbURL: URL) throws -> Int {
    var db: OpaquePointer?
    guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
        throw SQLiteTestError.openFailed
    }

    defer {
        sqlite3_close(db)
    }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table);", -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw SQLiteTestError.prepareFailed
    }

    defer {
        sqlite3_finalize(statement)
    }

    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw SQLiteTestError.stepFailed
    }

    return Int(sqlite3_column_int(statement, 0))
}

private enum SQLiteTestError: Error {
    case openFailed
    case prepareFailed
    case stepFailed
}
