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

    @Test
    func purgeRemovesOldSamplesButKeepsReferenceRows() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "purge")
        let store = HistoryStore(databaseURL: dbURL)

        let baseTime = Date(timeIntervalSince1970: 1_775_000_000)
        await store.append(makeSnapshot(timestamp: baseTime))
        await store.append(makeSnapshot(timestamp: baseTime.addingTimeInterval(10 * 24 * 3_600)))
        #expect(try tableCount("telemetry_samples", dbURL: dbURL) == 2)

        await store.purge(olderThan: baseTime.addingTimeInterval(5 * 24 * 3_600), rollupBucketSeconds: nil)

        #expect(try tableCount("telemetry_samples", dbURL: dbURL) == 1)
        #expect(try tableCount("history_rollups", dbURL: dbURL) == 0)
        // De-duplicated dimension rows are preserved so long-term trends survive.
        #expect(try tableCount("batteries", dbURL: dbURL) == 1)
        #expect(try tableCount("battery_states", dbURL: dbURL) == 1)
        #expect(try tableCount("adapters", dbURL: dbURL) == 1)
        #expect(try tableCount("apps", dbURL: dbURL) == 1)

        let loaded = await store.loadRecent(since: baseTime.addingTimeInterval(-1))
        #expect(loaded.count == 1)
        #expect(loaded.first?.timestamp == baseTime.addingTimeInterval(10 * 24 * 3_600))
    }

    @Test
    func purgeRollsUpOldSamplesIntoBuckets() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "rollup")
        let store = HistoryStore(databaseURL: dbURL)

        let day0 = Date(timeIntervalSince1970: 1_700_000_000)
        await store.append(makeSnapshot(timestamp: day0, systemLoadW: 10))
        await store.append(makeSnapshot(timestamp: day0.addingTimeInterval(3_600), systemLoadW: 20))
        let recent = day0.addingTimeInterval(40 * 24 * 3_600)
        await store.append(makeSnapshot(timestamp: recent, systemLoadW: 30))
        #expect(try tableCount("telemetry_samples", dbURL: dbURL) == 3)

        await store.purge(olderThan: day0.addingTimeInterval(10 * 24 * 3_600), rollupBucketSeconds: 86_400)

        // The two old same-day samples collapse into one rollup; the recent sample stays raw.
        #expect(try tableCount("telemetry_samples", dbURL: dbURL) == 1)
        #expect(try tableCount("history_rollups", dbURL: dbURL) == 1)

        let rollups = await store.rollupSeries(for: DateInterval(start: Date(timeIntervalSince1970: 0), end: recent))
        #expect(rollups.count == 1)
        #expect(rollups.first?.sampleCount == 2)
        #expect(abs((rollups.first?.avgSystemLoadW ?? 0) - 15) < 0.001)
        #expect(abs((rollups.first?.maxSystemLoadW ?? 0) - 20) < 0.001)

        let loaded = await store.loadRecent(since: Date(timeIntervalSince1970: 0))
        #expect(loaded.count == 1)
        #expect(loaded.first?.timestamp == recent)
    }

    @Test
    func aggregatedSeriesGroupsSamplesIntoBuckets() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "aggregate")
        let store = HistoryStore(databaseURL: dbURL)

        let baseTime = Date(timeIntervalSince1970: 1_775_000_000)
        let loads: [(TimeInterval, Double)] = [
            (0, 10), (60, 20), (120, 30),
            (3_700, 40), (3_760, 50),
        ]
        for (offset, load) in loads {
            await store.append(makeSnapshot(timestamp: baseTime.addingTimeInterval(offset), systemLoadW: load))
        }

        let range = DateInterval(start: baseTime.addingTimeInterval(-1), end: baseTime.addingTimeInterval(7_200))
        let series = await store.aggregatedSeries(for: range, bucketSeconds: 3_600)

        #expect(series.count == 2)
        #expect(series.first?.sampleCount == 3)
        #expect(series.last?.sampleCount == 2)
        #expect(abs((series.first?.avgSystemLoadW ?? 0) - 20) < 0.001)
        #expect(abs((series.last?.avgSystemLoadW ?? 0) - 45) < 0.001)
        #expect(abs((series.last?.maxSystemLoadW ?? 0) - 50) < 0.001)
    }

    @Test
    func summaryComputesAggregateStatistics() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "summary")
        let store = HistoryStore(databaseURL: dbURL)

        let baseTime = Date(timeIntervalSince1970: 1_775_100_000)
        await store.append(makeSnapshot(timestamp: baseTime, systemLoadW: 10))
        await store.append(makeSnapshot(timestamp: baseTime.addingTimeInterval(60), systemLoadW: 20))
        await store.append(makeSnapshot(timestamp: baseTime.addingTimeInterval(120), systemLoadW: 30))

        let range = DateInterval(start: baseTime.addingTimeInterval(-1), end: baseTime.addingTimeInterval(300))
        let summary = await store.summary(for: range)

        #expect(summary.sampleCount == 3)
        #expect(abs((summary.avgSystemLoadW ?? 0) - 20) < 0.001)
        #expect(abs((summary.maxSystemLoadW ?? 0) - 30) < 0.001)
        #expect(abs(summary.timeOnExternal - 120) < 0.001)
        #expect(summary.timeOnBattery == 0)
    }

    @Test
    func summaryCountsChargeSessionsAndBatteryTime() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "summary-sessions")
        let store = HistoryStore(databaseURL: dbURL)

        let baseTime = Date(timeIntervalSince1970: 1_775_300_000)
        await store.append(makeSnapshot(timestamp: baseTime, externalConnected: false, isCharging: false))
        await store.append(makeSnapshot(timestamp: baseTime.addingTimeInterval(60), externalConnected: false, isCharging: false))
        await store.append(makeSnapshot(timestamp: baseTime.addingTimeInterval(120), externalConnected: true, isCharging: true))
        await store.append(makeSnapshot(timestamp: baseTime.addingTimeInterval(180), externalConnected: true, isCharging: true))

        let range = DateInterval(start: baseTime.addingTimeInterval(-1), end: baseTime.addingTimeInterval(300))
        let summary = await store.summary(for: range)

        #expect(summary.chargeSessions == 1)
        #expect(abs(summary.timeOnBattery - 120) < 0.001)
        #expect(abs(summary.timeOnExternal - 60) < 0.001)
    }

    @Test
    func batteryHealthTrendReturnsPointPerDistinctState() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "health-trend")
        let store = HistoryStore(databaseURL: dbURL)

        let baseTime = Date(timeIntervalSince1970: 1_775_200_000)
        await store.append(makeSnapshot(timestamp: baseTime, cycleCount: 74, fullChargeCapacityMah: 5637))
        await store.append(makeSnapshot(timestamp: baseTime.addingTimeInterval(86_400), cycleCount: 75, fullChargeCapacityMah: 5600))

        let trend = await store.batteryHealthTrend(since: baseTime.addingTimeInterval(-1))

        #expect(trend.count == 2)
        #expect(trend.first?.cycleCount == 74)
        #expect(trend.first?.fullChargeCapacityMah == 5637)
        #expect(trend.last?.cycleCount == 75)
        #expect(trend.last?.designCapacityMah == 6249)
        #expect(abs((trend.first?.healthPercent ?? 0) - (5637.0 / 6249.0 * 100)) < 0.001)
    }
}

private func makeSnapshot(
    timestamp: Date,
    cycleCount: Int = 74,
    fullChargeCapacityMah: Int = 5637,
    nominalCapacityMah: Int = 5874,
    systemLoadW: Double = 22.36,
    batteryTemperatureC: Double = 29.5,
    externalConnected: Bool = true,
    isCharging: Bool = false
) -> TelemetrySnapshot {
    TelemetrySnapshot(
        timestamp: timestamp,
        batteryLevel: 80,
        powerSource: externalConnected ? .ac : .battery,
        isCharging: isCharging,
        isCharged: false,
        externalConnected: externalConnected,
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
