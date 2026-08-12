import Foundation
import SQLite3
import Testing
@testable import PowerLens

struct HistoryStoreTests {
    @Test
    func liveChargingPolicyIsNotPersisted() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "live-policy-not-persisted")
        let store = HistoryStore(databaseURL: dbURL)
        let timestamp = Date(timeIntervalSince1970: 1_775_627_900)
        let liveSnapshot = makeSnapshot(timestamp: timestamp)
            .withChargingPolicyStatus(.manualLimit(targetPercent: 87))

        try await store.append(liveSnapshot)

        let loaded = try await store.loadRecent(
            since: timestamp.addingTimeInterval(-1)
        )
        #expect(loaded.count == 1)
        #expect(loaded.first?.chargingPolicyStatus == nil)
    }

    @Test
    func preservesBatteryPowerValueAndSource() async throws {
        let dbURL = makeTemporaryDatabaseURL(
            name: "battery-power-provenance"
        )
        let store = HistoryStore(databaseURL: dbURL)
        let timestamp = Date(timeIntervalSince1970: 1_775_627_950)
        let snapshot = makeSnapshot(
            timestamp: timestamp,
            batteryPowerW: 10.045,
            batteryPowerSource: .currentAndVoltage
        )

        try await store.append(snapshot)

        let loaded = try await store.loadRecent(
            since: timestamp.addingTimeInterval(-1)
        )
        #expect(loaded.count == 1)
        #expect(loaded.first?.batteryPowerW == 10.045)
        #expect(
            loaded.first?.batteryPowerSource == .currentAndVoltage
        )
        #expect(
            try databaseUserVersion(dbURL)
                == HistorySchema.currentVersion
        )
    }

    @Test
    func databaseOpenFailureIsReportedToTheCaller() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PowerLensTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let blockingFile = directory.appendingPathComponent("not-a-directory")
        #expect(
            FileManager.default.createFile(
                atPath: blockingFile.path,
                contents: Data()
            )
        )
        let store = HistoryStore(
            databaseURL: blockingFile.appendingPathComponent("history.sqlite3")
        )

        var receivedError: (any Error)?
        do {
            _ = try await store.loadRecent(
                since: Date(timeIntervalSince1970: 0)
            )
        } catch {
            receivedError = error
        }

        #expect(receivedError is HistoryStoreError)
    }

    @Test
    func migratesHistoryWithoutBatteryPowerSourceColumn() async throws {
        let dbURL = makeTemporaryDatabaseURL(
            name: "battery-power-provenance-migration"
        )
        try createLegacyTelemetrySamplesTable(at: dbURL)

        let store = HistoryStore(databaseURL: dbURL)
        let timestamp = Date(timeIntervalSince1970: 1_775_627_975)
        try await store.append(
            makeSnapshot(
                timestamp: timestamp,
                batteryPowerW: -43.447,
                batteryPowerSource: .currentAndVoltage
            )
        )

        let loaded = try await store.loadRecent(
            since: timestamp.addingTimeInterval(-1)
        )
        #expect(loaded.count == 1)
        #expect(loaded.first?.batteryPowerW == -43.447)
        #expect(
            loaded.first?.batteryPowerSource == .currentAndVoltage
        )
    }

    @Test
    func reusesReferenceRowsForRepeatedSamples() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "reused-references")
        let store = HistoryStore(databaseURL: dbURL)

        let baseTime = Date(timeIntervalSince1970: 1_775_628_000)
        let first = makeSnapshot(timestamp: baseTime, systemLoadW: 22.3, batteryTemperatureC: 29.4)
        let second = makeSnapshot(timestamp: baseTime.addingTimeInterval(60), systemLoadW: 26.1, batteryTemperatureC: 30.2)

        try await store.append(first)
        try await store.append(second)

        #expect(try tableCount("batteries", dbURL: dbURL) == 1)
        #expect(try tableCount("battery_states", dbURL: dbURL) == 1)
        #expect(try tableCount("adapters", dbURL: dbURL) == 1)
        #expect(try tableCount("apps", dbURL: dbURL) == 1)
        #expect(try tableCount("telemetry_samples", dbURL: dbURL) == 2)

        let loaded = try await store.loadRecent(since: baseTime.addingTimeInterval(-120))
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

        try await store.append(first)
        try await store.append(second)

        #expect(try tableCount("batteries", dbURL: dbURL) == 1)
        #expect(try tableCount("battery_states", dbURL: dbURL) == 2)
        #expect(try tableCount("telemetry_samples", dbURL: dbURL) == 2)

        let loaded = try await store.loadRecent(since: baseTime.addingTimeInterval(-120))
        #expect(loaded.last?.cycleCount == 75)
        #expect(loaded.last?.fullChargeCapacityMah == 5600)
        #expect(loaded.last?.nominalCapacityMah == 5840)
    }

    @Test
    func purgeWithoutRollupsRemovesUnreferencedMetadata() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "purge")
        let store = HistoryStore(databaseURL: dbURL)

        let baseTime = Date(timeIntervalSince1970: 1_775_000_000)
        try await store.append(
            makeSnapshot(
                timestamp: baseTime,
                cycleCount: 73,
                adapterDescription: "Old Charger",
                serialNumber: "OLD-BATTERY",
                appBundleID: "example.old",
                appName: "Old App"
            )
        )
        try await store.append(
            makeSnapshot(
                timestamp: baseTime.addingTimeInterval(10 * 24 * 3_600),
                adapterDescription: "Current Charger",
                serialNumber: "CURRENT-BATTERY",
                appBundleID: "example.current",
                appName: "Current App"
            )
        )
        #expect(try tableCount("telemetry_samples", dbURL: dbURL) == 2)
        #expect(try tableCount("batteries", dbURL: dbURL) == 2)
        #expect(try tableCount("battery_states", dbURL: dbURL) == 2)
        #expect(try tableCount("adapters", dbURL: dbURL) == 2)
        #expect(try tableCount("apps", dbURL: dbURL) == 2)

        try await store.purge(olderThan: baseTime.addingTimeInterval(5 * 24 * 3_600), rollupBucketSeconds: nil)

        #expect(try tableCount("telemetry_samples", dbURL: dbURL) == 1)
        #expect(try tableCount("history_rollups", dbURL: dbURL) == 0)
        #expect(try tableCount("batteries", dbURL: dbURL) == 1)
        #expect(try tableCount("battery_states", dbURL: dbURL) == 1)
        #expect(try tableCount("adapters", dbURL: dbURL) == 1)
        #expect(try tableCount("apps", dbURL: dbURL) == 1)

        let loaded = try await store.loadRecent(since: baseTime.addingTimeInterval(-1))
        #expect(loaded.count == 1)
        #expect(loaded.first?.timestamp == baseTime.addingTimeInterval(10 * 24 * 3_600))
    }

    @Test
    func purgeRollsUpOldSamplesIntoBuckets() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "rollup")
        let store = HistoryStore(databaseURL: dbURL)

        let day0 = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.append(
            makeSnapshot(
                timestamp: day0,
                systemLoadW: 10,
                adapterDescription: "Old Charger",
                serialNumber: "OLD-BATTERY",
                appBundleID: "example.old",
                appName: "Old App"
            )
        )
        try await store.append(
            makeSnapshot(
                timestamp: day0.addingTimeInterval(3_600),
                systemLoadW: 20,
                adapterDescription: "Old Charger",
                serialNumber: "OLD-BATTERY",
                appBundleID: "example.old",
                appName: "Old App"
            )
        )
        let recent = day0.addingTimeInterval(40 * 24 * 3_600)
        try await store.append(
            makeSnapshot(
                timestamp: recent,
                systemLoadW: 30,
                adapterDescription: "Current Charger",
                serialNumber: "CURRENT-BATTERY",
                appBundleID: "example.current",
                appName: "Current App"
            )
        )
        #expect(try tableCount("telemetry_samples", dbURL: dbURL) == 3)

        try await store.purge(olderThan: day0.addingTimeInterval(10 * 24 * 3_600), rollupBucketSeconds: 86_400)

        // The two old same-day samples collapse into one rollup; the recent sample stays raw.
        #expect(try tableCount("telemetry_samples", dbURL: dbURL) == 1)
        #expect(try tableCount("history_rollups", dbURL: dbURL) == 1)
        #expect(try tableCount("adapters", dbURL: dbURL) == 1)
        #expect(try tableCount("apps", dbURL: dbURL) == 1)
        // Battery health records remain available for the long-term trend.
        #expect(try tableCount("batteries", dbURL: dbURL) == 2)
        #expect(try tableCount("battery_states", dbURL: dbURL) == 2)

        let rollups = try await store.rollupSeries(for: DateInterval(start: Date(timeIntervalSince1970: 0), end: recent))
        #expect(rollups.count == 1)
        #expect(rollups.first?.sampleCount == 2)
        #expect(abs((rollups.first?.avgSystemLoadW ?? 0) - 15) < 0.001)
        #expect(abs((rollups.first?.maxSystemLoadW ?? 0) - 20) < 0.001)

        let loaded = try await store.loadRecent(since: Date(timeIntervalSince1970: 0))
        #expect(loaded.count == 1)
        #expect(loaded.first?.timestamp == recent)
    }

    @Test
    func summaryIncludesRolledUpData() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "summary-rollup")
        let store = HistoryStore(databaseURL: dbURL)

        let day0 = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.append(makeSnapshot(timestamp: day0, systemLoadW: 10, externalConnected: false, isCharging: false))
        try await store.append(makeSnapshot(timestamp: day0.addingTimeInterval(60), systemLoadW: 20, externalConnected: false, isCharging: false))
        try await store.append(makeSnapshot(timestamp: day0.addingTimeInterval(120), systemLoadW: 30, externalConnected: true, isCharging: true))
        let recent = day0.addingTimeInterval(40 * 24 * 3_600)
        try await store.append(makeSnapshot(timestamp: recent, systemLoadW: 40, externalConnected: true, isCharging: false))

        try await store.purge(olderThan: day0.addingTimeInterval(10 * 24 * 3_600), rollupBucketSeconds: 86_400)
        #expect(try tableCount("telemetry_samples", dbURL: dbURL) == 1)
        #expect(try tableCount("history_rollups", dbURL: dbURL) == 1)

        let summary = try await store.summary(for: DateInterval(start: Date(timeIntervalSince1970: 0), end: recent.addingTimeInterval(60)))
        #expect(summary.sampleCount == 4)
        #expect(summary.chargeSessions == 1)
        #expect(abs(summary.timeOnBattery - 120) < 0.001)
        #expect(abs((summary.avgSystemLoadW ?? 0) - 25) < 0.001)
        #expect(abs((summary.maxSystemLoadW ?? 0) - 40) < 0.001)
    }

    @Test
    func purgeWithResolutionOffDiscardsExistingRollups() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "rollup-off")
        let store = HistoryStore(databaseURL: dbURL)

        let day0 = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.append(makeSnapshot(timestamp: day0))
        try await store.append(makeSnapshot(timestamp: day0.addingTimeInterval(60)))

        try await store.purge(olderThan: day0.addingTimeInterval(10 * 24 * 3_600), rollupBucketSeconds: 86_400)
        #expect(try tableCount("history_rollups", dbURL: dbURL) == 1)

        try await store.purge(olderThan: day0.addingTimeInterval(20 * 24 * 3_600), rollupBucketSeconds: nil)
        #expect(try tableCount("history_rollups", dbURL: dbURL) == 0)
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
            try await store.append(makeSnapshot(timestamp: baseTime.addingTimeInterval(offset), systemLoadW: load))
        }

        let range = DateInterval(start: baseTime.addingTimeInterval(-1), end: baseTime.addingTimeInterval(7_200))
        let series = try await store.aggregatedSeries(for: range, bucketSeconds: 3_600)

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
        try await store.append(makeSnapshot(timestamp: baseTime, systemLoadW: 10))
        try await store.append(makeSnapshot(timestamp: baseTime.addingTimeInterval(60), systemLoadW: 20))
        try await store.append(makeSnapshot(timestamp: baseTime.addingTimeInterval(120), systemLoadW: 30))

        let range = DateInterval(start: baseTime.addingTimeInterval(-1), end: baseTime.addingTimeInterval(300))
        let summary = try await store.summary(for: range)

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
        try await store.append(makeSnapshot(timestamp: baseTime, externalConnected: false, isCharging: false))
        try await store.append(makeSnapshot(timestamp: baseTime.addingTimeInterval(60), externalConnected: false, isCharging: false))
        try await store.append(makeSnapshot(timestamp: baseTime.addingTimeInterval(120), externalConnected: true, isCharging: true))
        try await store.append(makeSnapshot(timestamp: baseTime.addingTimeInterval(180), externalConnected: true, isCharging: true))

        let range = DateInterval(start: baseTime.addingTimeInterval(-1), end: baseTime.addingTimeInterval(300))
        let summary = try await store.summary(for: range)

        #expect(summary.chargeSessions == 1)
        #expect(abs(summary.timeOnBattery - 120) < 0.001)
        #expect(abs(summary.timeOnExternal - 60) < 0.001)
    }

    @Test
    func batteryHealthTrendReturnsPointPerDistinctState() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "health-trend")
        let store = HistoryStore(databaseURL: dbURL)

        let baseTime = Date(timeIntervalSince1970: 1_775_200_000)
        try await store.append(makeSnapshot(timestamp: baseTime, cycleCount: 74, fullChargeCapacityMah: 5637))
        try await store.append(makeSnapshot(timestamp: baseTime.addingTimeInterval(86_400), cycleCount: 75, fullChargeCapacityMah: 5600))

        let trend = try await store.batteryHealthTrend(since: baseTime.addingTimeInterval(-1))

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
    batteryPowerW: Double = 0,
    batteryPowerSource: BatteryPowerSource? = nil,
    externalConnected: Bool = true,
    isCharging: Bool = false,
    adapterDescription: String = "PD Charger",
    serialNumber: String = "F5DH2H0043N00000EB",
    appBundleID: String = "com.openai.codex",
    appName: String = "Codex"
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
        batteryPowerW: batteryPowerW,
        batteryPowerSource: batteryPowerSource,
        adapterDescription: adapterDescription,
        adapterMaxPowerW: 97,
        adapterInputPowerW: 20.92,
        adapterVoltageV: 19.26,
        adapterCurrentA: 1.09,
        systemLoadW: systemLoadW,
        lowPowerModeEnabled: false,
        thermalState: "Nominal",
        serialNumber: serialNumber,
        frontmostAppBundleID: appBundleID,
        frontmostAppName: appName
    )
}

private func makeTemporaryDatabaseURL(name: String) -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PowerLensTests", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("\(name)-\(UUID().uuidString).sqlite3")
}

private func createLegacyTelemetrySamplesTable(at dbURL: URL) throws {
    var db: OpaquePointer?
    guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
        throw SQLiteTestError.openFailed
    }

    defer {
        sqlite3_close(db)
    }

    let sql = """
    CREATE TABLE telemetry_samples (
        sample_id INTEGER PRIMARY KEY,
        ts INTEGER NOT NULL,
        battery_id INTEGER,
        battery_state_id INTEGER,
        adapter_id INTEGER,
        app_id INTEGER,
        power_source_code INTEGER NOT NULL,
        thermal_state_code INTEGER NOT NULL,
        is_charging INTEGER NOT NULL,
        is_charged INTEGER NOT NULL,
        external_connected INTEGER NOT NULL,
        low_power_mode_enabled INTEGER NOT NULL,
        battery_level_x10 INTEGER,
        time_to_empty_minutes INTEGER,
        time_to_full_minutes INTEGER,
        battery_temperature_c_x100 INTEGER,
        battery_voltage_mv INTEGER,
        battery_current_ma INTEGER,
        battery_power_mw INTEGER,
        adapter_input_power_mw INTEGER,
        adapter_voltage_mv INTEGER,
        adapter_current_ma INTEGER,
        system_load_mw INTEGER
    );
    """
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw SQLiteTestError.stepFailed
    }
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

private func databaseUserVersion(_ dbURL: URL) throws -> Int {
    var db: OpaquePointer?
    guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
        throw SQLiteTestError.openFailed
    }

    defer {
        sqlite3_close(db)
    }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        db,
        "PRAGMA user_version;",
        -1,
        &statement,
        nil
    ) == SQLITE_OK,
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
