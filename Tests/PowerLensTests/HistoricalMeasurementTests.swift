import Foundation
import SQLite3
import Testing
@testable import PowerLens

struct HistoricalMeasurementTests {
    @Test(arguments: [0.3504, -0.3504, -9.093])
    func realDatabasePreservesFlowProvenanceAndThresholdPrecision(power: Double) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let snapshot = makeTelemetrySnapshot(timestamp: Date(timeIntervalSince1970: 2_000_000_000.123),
            batteryCurrentA: -1.196, batteryPowerW: power, batteryPowerSource: .directTelemetry,
            adapterInputPowerW: 31.686, systemLoadW: 19.647, powerMeasurementSetSource: .smc)
        try await store.append(snapshot)
        let rows = try await store.loadRecent(since: snapshot.timestamp.addingTimeInterval(-1))
        let restored = try #require(rows.first)
        #expect(restored.timestamp == snapshot.timestamp)
        #expect(restored.powerMeasurementSetSource == .smc)
        #expect(restored.batteryPowerW == power)
        #expect(PowerFlowReadings(snapshot: restored) == PowerFlowReadings(snapshot: snapshot))
        #expect(RecentPowerSample(snapshot: restored).inputW == RecentPowerSample(snapshot: snapshot).inputW)
    }

    @Test
    func preciseTimestampsControlFilteringAndOrderWithinOneSecond() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        for offset in [0.4, 0.1, 0.3] {
            try await store.append(makeTelemetrySnapshot(timestamp: start.addingTimeInterval(offset)))
        }
        let rows = try await store.loadRecentRecords(since: start.addingTimeInterval(0.2))
        #expect(rows.map(\.snapshot.timestamp) == [0.3, 0.4].map { start.addingTimeInterval($0) })
    }

    @Test
    func duplicateTimesHaveDistinctStableChartIdentities() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let snapshot = makeTelemetrySnapshot()
        try await store.append(snapshot)
        try await store.append(snapshot)
        let first = try await store.loadRecentRecords(since: snapshot.timestamp)
        let second = try await store.loadRecentRecords(since: snapshot.timestamp)
        #expect(first.count == 2)
        #expect(Set(first.map(\.id)).count == 2)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(Set(first.map { RecentPowerSample(record: $0).id }).count == 2)
    }

    @Test
    func migrationRetainsUnknownLegacyProvenanceAndAPreUpgradeBackup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite3")
        let store = HistoryStore(databaseURL: url)
        let sample = makeTelemetrySnapshot(batteryPowerW: 0.3504, powerMeasurementSetSource: .smc)
        try await store.append(sample)
        try sql(url, "ALTER TABLE telemetry_samples DROP COLUMN measurement_payload; PRAGMA user_version = 4;")
        let restored = try await store.loadRecent(since: sample.timestamp)
        #expect(restored.first?.powerMeasurementSetSource == nil)
        #expect(restored.first?.batteryPowerW == 0.35)
        let backup = HistoryDatabaseBackup.url(for: url, schemaVersion: 4)
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try version(backup) == 4)
        #expect(try version(url) == 5)
        let bytes = try Data(contentsOf: backup)
        _ = try await store.loadRecent(since: sample.timestamp)
        #expect(try Data(contentsOf: backup) == bytes)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".history-backup-") }
        #expect(leftovers.isEmpty)
    }

    @Test
    func eachUpgradeKeepsItsOwnBackup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite3")
        let store = HistoryStore(databaseURL: url)
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        try await store.append(makeTelemetrySnapshot(timestamp: date))
        try sql(url, "PRAGMA user_version = 4;")
        _ = try await store.loadRecent(since: date)
        try sql(url, "PRAGMA user_version = 3;")
        _ = try await store.loadRecent(since: date)
        let backups = [3, 4].map { HistoryDatabaseBackup.url(for: url, schemaVersion: $0) }
        #expect(try backups.map(version) == [3, 4])
        #expect(try Set(HistoryDatabaseBackup.existingBackups(for: url)) == Set(backups))
        try await store.removeExpiredBackups(now: date, discardingAll: true)
        #expect(try HistoryDatabaseBackup.existingBackups(for: url).isEmpty)
    }

    @Test
    func preUpgradeBackupOutlivesSampleRetentionForFourteenDays() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite3")
        let store = HistoryStore(databaseURL: url)
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        try await store.append(makeTelemetrySnapshot(timestamp: date))
        try sql(url, "ALTER TABLE telemetry_samples DROP COLUMN measurement_payload; PRAGMA user_version = 4;")
        _ = try await store.loadRecent(since: date)
        let backup = HistoryDatabaseBackup.url(for: url, schemaVersion: 4)
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: backup.path)

        // Its only sample has expired, but the copy stays for going back.
        try await store.purge(olderThan: date.addingTimeInterval(3_600), rollupBucketSeconds: 3_600)
        try await store.removeExpiredBackups(now: date.addingTimeInterval(13 * 86_400), discardingAll: false)
        #expect(FileManager.default.fileExists(atPath: backup.path))

        try await store.removeExpiredBackups(now: date.addingTimeInterval(14 * 86_400), discardingAll: false)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    @Test
    func disablingLongTermHistoryAlsoRemovesTheRollbackCopy() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite3")
        let store = HistoryStore(databaseURL: url)
        let sample = makeTelemetrySnapshot()
        try await store.append(sample)
        try sql(url, "ALTER TABLE telemetry_samples DROP COLUMN measurement_payload; PRAGMA user_version = 4;")
        _ = try await store.loadRecent(since: sample.timestamp)
        let backup = HistoryDatabaseBackup.url(for: url, schemaVersion: 4)
        #expect(FileManager.default.fileExists(atPath: backup.path))
        try await store.removeExpiredBackups(now: sample.timestamp, discardingAll: true)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(try await store.loadRecent(since: sample.timestamp).count == 1)
    }

    @Test
    func backupCleanupRemovesFilesLeftByAnInterruptedBackup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite3")
        let store = HistoryStore(databaseURL: url)
        try await store.append(makeTelemetrySnapshot())
        for name in [".history-backup-A", ".history-backup-A-shm", ".history-backup-B-wal"] {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        try await store.removeExpiredBackups(now: Date(), discardingAll: false)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!remaining.contains { $0.hasPrefix(".history-backup-") })
        #expect(remaining.contains("history.sqlite3"))
    }

    @Test(arguments: [
        (TimeInterval?.some(86_400), Int?.none, true),
        (86_400, 3_600, false),
        (nil, nil, false),
        (nil, 3_600, false),
    ])
    func onlyDontKeepDiscardsBackupsEarly(rawWindow: TimeInterval?, bucketSeconds: Int?, discards: Bool) {
        #expect(HistoryDatabaseBackup.discardsAll(rawWindow: rawWindow, rollupBucketSeconds: bucketSeconds) == discards)
    }

    @Test
    func malformedPrecisionPayloadIsAReadFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite3")
        let store = HistoryStore(databaseURL: url)
        let sample = makeTelemetrySnapshot()
        try await store.append(sample)
        try sql(url, "UPDATE telemetry_samples SET measurement_payload = 'broken';")
        await #expect(throws: (any Error).self) {
            _ = try await store.loadRecent(since: sample.timestamp)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("powerlens-history-regression-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sql(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let connection = try #require(db)
        defer { sqlite3_close(connection) }
        try SQLiteStatement.execute(sql, using: connection)
    }

    private func version(_ url: URL) throws -> Int64? {
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        let connection = try #require(db)
        defer { sqlite3_close(connection) }
        return try SQLiteStatement.querySingleInt64("PRAGMA user_version;", using: connection) { _ in }
    }
}
