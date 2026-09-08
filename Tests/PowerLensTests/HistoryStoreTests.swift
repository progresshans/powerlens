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
    func summaryPreservesMissingSensorAveragesAfterPurging() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "rollup-missing-values")
        let store = HistoryStore(databaseURL: dbURL)
        let day = Date(timeIntervalSince1970: 1_728_000_000)
        try await store.append(makeSnapshot(
            timestamp: day,
            systemLoadW: 10.001,
            batteryTemperatureC: 20.01,
            adapterInputPowerW: 50.003
        ))
        try await store.append(makeSnapshot(
            timestamp: day.addingTimeInterval(60),
            systemLoadW: nil,
            batteryTemperatureC: nil,
            adapterInputPowerW: nil
        ))
        try await store.append(makeSnapshot(
            timestamp: day.addingTimeInterval(120),
            systemLoadW: 10.002,
            batteryTemperatureC: 20.02,
            adapterInputPowerW: 50.004
        ))
        try await store.append(makeSnapshot(
            timestamp: day.addingTimeInterval(2 * 86_400),
            systemLoadW: 30,
            batteryTemperatureC: 40,
            adapterInputPowerW: 90
        ))
        let range = DateInterval(start: day, duration: 3 * 86_400)
        let before = try await store.summary(for: range)

        try await store.purge(
            olderThan: day.addingTimeInterval(86_400),
            rollupBucketSeconds: 86_400
        )
        let after = try await store.summary(for: range)
        let rollups = try await store.rollupSeries(for: range)

        #expect(after.sampleCount == before.sampleCount)
        #expect(abs((after.avgSystemLoadW ?? 0) - (before.avgSystemLoadW ?? 0)) < 0.000_000_001)
        #expect(abs((after.avgAdapterInputPowerW ?? 0) - (before.avgAdapterInputPowerW ?? 0)) < 0.000_000_001)
        #expect(abs((after.avgTemperatureC ?? 0) - (before.avgTemperatureC ?? 0)) < 0.000_000_001)
        #expect(abs((rollups.first?.avgSystemLoadW ?? 0) - 10.0015) < 0.000_000_001)
        #expect(abs((rollups.first?.avgAdapterInputPowerW ?? 0) - 50.0035) < 0.000_000_001)
        #expect(abs((rollups.first?.avgTemperatureC ?? 0) - 20.015) < 0.000_000_001)
    }

    @Test
    func chargeSessionsStayStableAcrossRepeatedPurgeBoundaries() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "rollup-charge-boundaries")
        let store = HistoryStore(databaseURL: dbURL)
        let day = Date(timeIntervalSince1970: 1_728_000_000)
        let observations: [(TimeInterval, Bool)] = [
            (86_340, true),
            (86_400, true),
            (86_460, false),
            (86_520, true),
            (2 * 86_400, true),
        ]
        for (offset, charging) in observations {
            try await store.append(makeSnapshot(
                timestamp: day.addingTimeInterval(offset),
                isCharging: charging
            ))
        }
        let range = DateInterval(start: day, duration: 3 * 86_400)
        #expect(try await store.summary(for: range).chargeSessions == 2)

        for dayCount in 1...3 {
            try await store.purge(
                olderThan: day.addingTimeInterval(Double(dayCount) * 86_400),
                rollupBucketSeconds: 86_400
            )
            #expect(try await store.summary(for: range).chargeSessions == 2)
        }
    }

    @Test
    func rangeStartingWithAnOngoingChargeSurvivesRollup() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "rollup-ongoing-charge")
        let store = HistoryStore(databaseURL: dbURL)
        let day = Date(timeIntervalSince1970: 1_728_000_000)
        for offset in [0.0, 86_400, 86_460] {
            try await store.append(makeSnapshot(
                timestamp: day.addingTimeInterval(offset),
                isCharging: true
            ))
        }
        let range = DateInterval(
            start: day.addingTimeInterval(86_400),
            duration: 86_400
        )
        #expect(try await store.summary(for: range).chargeSessions == 1)
        try await store.purge(
            olderThan: range.end,
            rollupBucketSeconds: 86_400
        )
        #expect(try await store.summary(for: range).chargeSessions == 1)
    }

    @Test
    func versionThreeRollupsKeepLegacyEstimatesDuringMigration() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "rollup-v3-migration")
        let day = Date(timeIntervalSince1970: 1_728_000_000)
        try createVersionThreeHistory(at: dbURL, bucketStart: Int64(day.timeIntervalSince1970))
        let store = HistoryStore(databaseURL: dbURL)
        let range = DateInterval(start: day, duration: 3 * 86_400)

        let migrated = try await store.summary(for: range)
        #expect(migrated.sampleCount == 2)
        #expect(migrated.avgSystemLoadW == 10)
        #expect(migrated.avgAdapterInputPowerW == 20)
        #expect(migrated.avgTemperatureC == 30)
        #expect(migrated.chargeSessions == 1)
        #expect(migrated.timeOnExternal == 120)
        #expect(try tableCount("history_rollups", dbURL: dbURL) == 1)
        #expect(try databaseUserVersion(dbURL) == HistorySchema.currentVersion)

        try await store.append(makeSnapshot(
            timestamp: day.addingTimeInterval(86_400),
            systemLoadW: 30,
            batteryTemperatureC: 50,
            adapterInputPowerW: 40,
            isCharging: true
        ))
        try await store.append(makeSnapshot(
            timestamp: day.addingTimeInterval(86_460),
            systemLoadW: nil,
            batteryTemperatureC: nil,
            adapterInputPowerW: nil,
            isCharging: true
        ))
        let before = try await store.summary(for: range)
        try await store.purge(
            olderThan: day.addingTimeInterval(2 * 86_400),
            rollupBucketSeconds: 86_400
        )
        let after = try await store.summary(for: range)

        #expect(after.sampleCount == 4)
        #expect(abs((after.avgSystemLoadW ?? 0) - (before.avgSystemLoadW ?? 0)) < 0.000_000_001)
        #expect(abs((after.avgAdapterInputPowerW ?? 0) - (before.avgAdapterInputPowerW ?? 0)) < 0.000_000_001)
        #expect(abs((after.avgTemperatureC ?? 0) - (before.avgTemperatureC ?? 0)) < 0.000_000_001)
        // Legacy records have no boundary state. Keep their session estimate;
        // do not invent continuity between an old bucket and new observations.
        #expect(before.chargeSessions == 2)
        #expect(after.chargeSessions == 2)
        #expect(try tableCount("history_rollups", dbURL: dbURL) == 2)
        #expect(try await store.loadRecent(since: day).isEmpty)
    }

    @Test
    func missingOnlyRollupsDoNotInventSensorValues() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "rollup-all-missing")
        let store = HistoryStore(databaseURL: dbURL)
        let day = Date(timeIntervalSince1970: 1_728_000_000)
        try await store.append(makeSnapshot(
            timestamp: day,
            systemLoadW: nil,
            batteryTemperatureC: nil,
            adapterInputPowerW: nil
        ))
        let range = DateInterval(start: day, duration: 2 * 86_400)
        try await store.purge(
            olderThan: day.addingTimeInterval(86_400),
            rollupBucketSeconds: 86_400
        )

        let summary = try await store.summary(for: range)
        let rollup = try await store.rollupSeries(for: range).first
        #expect(summary.sampleCount == 1)
        #expect(summary.avgSystemLoadW == nil)
        #expect(summary.avgAdapterInputPowerW == nil)
        #expect(summary.avgTemperatureC == nil)
        #expect(rollup?.avgSystemLoadW == nil)
        #expect(rollup?.avgAdapterInputPowerW == nil)
        #expect(rollup?.avgTemperatureC == nil)
    }

    @Test
    func insightsKeepTheRawTailWithoutDuplicateBoundaryDates() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "insights-raw-boundary")
        let store = HistoryStore(databaseURL: dbURL)
        let day = Date(timeIntervalSince1970: 1_728_000_000)
        let firstRawDate = day.addingTimeInterval(10 * 3_600 + 900)
        try await store.append(makeSnapshot(timestamp: day, systemLoadW: 10))
        try await store.append(makeSnapshot(timestamp: firstRawDate, systemLoadW: 30))
        try await store.purge(
            olderThan: day.addingTimeInterval(10 * 3_600),
            rollupBucketSeconds: 3_600
        )

        let insights = try await store.loadInsights(
            for: .all,
            now: day.addingTimeInterval(11 * 3_600)
        )
        #expect(insights.series.count == 2)
        #expect(insights.series.map(\.bucketStart) == [day, firstRawDate])
        #expect(insights.series.map(\.sampleCount) == [1, 1])
        #expect(insights.summary.sampleCount == 2)
        #expect(insights.summary.avgSystemLoadW == 20)
    }

    @Test
    func mixedRollupResolutionsKeepDistinctObservationDates() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "insights-mixed-resolutions")
        let store = HistoryStore(databaseURL: dbURL)
        let day = Date(timeIntervalSince1970: 1_728_000_000)
        let later = day.addingTimeInterval(10 * 3_600)
        try await store.append(makeSnapshot(timestamp: day, systemLoadW: 10, isCharging: true))
        try await store.append(makeSnapshot(timestamp: later, systemLoadW: 30, isCharging: true))
        try await store.purge(olderThan: later, rollupBucketSeconds: 3_600)
        try await store.purge(
            olderThan: day.addingTimeInterval(86_400),
            rollupBucketSeconds: 86_400
        )

        let insights = try await store.loadInsights(
            for: .all,
            now: day.addingTimeInterval(2 * 86_400)
        )
        #expect(insights.series.map(\.bucketStart) == [day, later])
        #expect(insights.series.map(\.sampleCount) == [1, 1])
        #expect(insights.summary.sampleCount == 2)
        #expect(insights.summary.avgSystemLoadW == 20)
        #expect(insights.summary.chargeSessions == 1)
    }

    @Test
    func versionThreeMigrationPreservesExistingRawValues() async throws {
        let dbURL = makeTemporaryDatabaseURL(name: "raw-v3-migration")
        let day = Date(timeIntervalSince1970: 1_728_000_000)
        let rawDate = day.addingTimeInterval(86_400)
        try createVersionThreeHistory(
            at: dbURL,
            bucketStart: Int64(day.timeIntervalSince1970),
            rawTimestamp: Int64(rawDate.timeIntervalSince1970)
        )
        let store = HistoryStore(databaseURL: dbURL)

        let raw = try await store.loadRecent(since: day)
        #expect(raw.count == 1)
        #expect(raw.first?.timestamp == rawDate)
        #expect(raw.first?.batteryPowerW == -12.345)
        #expect(raw.first?.batteryPowerSource == .currentAndVoltage)
        #expect(raw.first?.systemLoadW == 22.36)
        #expect(try tableCount("telemetry_samples", dbURL: dbURL) == 1)
        #expect(try tableCount("history_rollups", dbURL: dbURL) == 1)
        #expect(try databaseUserVersion(dbURL) == HistorySchema.currentVersion)
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
    systemLoadW: Double? = 22.36,
    batteryTemperatureC: Double? = 29.5,
    adapterInputPowerW: Double? = 20.92,
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
        adapterInputPowerW: adapterInputPowerW,
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

private func createVersionThreeHistory(
    at dbURL: URL,
    bucketStart: Int64,
    rawTimestamp: Int64? = nil
) throws {
    try FileManager.default.createDirectory(
        at: dbURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    var connection: OpaquePointer?
    guard sqlite3_open(dbURL.path, &connection) == SQLITE_OK,
          let connection else {
        throw NSError(domain: "HistoryStoreTests", code: 1)
    }
    defer { sqlite3_close(connection) }

    // Keep the historical rollup definition independent of the current schema.
    // The other tables have not changed since version 3.
    let legacyRollups = """
    CREATE TABLE history_rollups (
        bucket_start INTEGER NOT NULL,
        bucket_seconds INTEGER NOT NULL,
        sample_count INTEGER NOT NULL,
        battery_level_avg_x10 INTEGER,
        battery_level_min_x10 INTEGER,
        battery_level_max_x10 INTEGER,
        adapter_input_power_avg_mw INTEGER,
        system_load_avg_mw INTEGER,
        system_load_max_mw INTEGER,
        battery_power_avg_mw INTEGER,
        battery_temperature_avg_c_x100 INTEGER,
        battery_temperature_max_c_x100 INTEGER,
        on_battery_seconds INTEGER,
        on_external_seconds INTEGER,
        charge_sessions INTEGER,
        PRIMARY KEY (bucket_start, bucket_seconds)
    );
    """
    for statement in HistorySchema.creationStatements {
        let sql = statement.contains("CREATE TABLE IF NOT EXISTS history_rollups")
            ? legacyRollups : statement
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "HistoryStoreTests", code: 2)
        }
    }
    let fixture = """
    INSERT INTO history_rollups (
        bucket_start, bucket_seconds, sample_count,
        battery_level_avg_x10, battery_level_min_x10, battery_level_max_x10,
        adapter_input_power_avg_mw, system_load_avg_mw, system_load_max_mw,
        battery_power_avg_mw, battery_temperature_avg_c_x100,
        battery_temperature_max_c_x100, on_battery_seconds,
        on_external_seconds, charge_sessions
    ) VALUES (\(bucketStart), 86400, 2, 800, 790, 810,
              20000, 10000, 15000, 0, 3000, 3200, 0, 120, 1);
    PRAGMA user_version = 3;
    """
    guard sqlite3_exec(connection, fixture, nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "HistoryStoreTests", code: 3)
    }
    if let rawTimestamp {
        let rawFixture = """
        INSERT INTO telemetry_samples (
            ts, power_source_code, thermal_state_code, is_charging, is_charged,
            external_connected, low_power_mode_enabled, battery_power_mw,
            system_load_mw, battery_power_source_code
        ) VALUES (\(rawTimestamp), 2, 1, 0, 0, 0, 0, -12345, 22360, 2);
        """
        guard sqlite3_exec(connection, rawFixture, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "HistoryStoreTests", code: 4)
        }
    }
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
