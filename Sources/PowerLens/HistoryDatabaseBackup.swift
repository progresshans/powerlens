import Foundation
import SQLite3

enum HistoryDatabaseBackup {
    /// How long a pre-upgrade copy stays available for going back to the
    /// previous app. It may hold samples past the retention window for this
    /// long; PRIVACY.md discloses it.
    static let retention: TimeInterval = 14 * 24 * 3_600

    private static let temporaryPrefix = ".history-backup-"

    /// A backup is named after the schema it holds, so each upgrade keeps its
    /// own copy instead of colliding with one left by an earlier upgrade.
    static func url(for database: URL, schemaVersion: Int) -> URL {
        database.appendingPathExtension("schema-v\(schemaVersion).sqlite3")
    }

    /// Every pre-upgrade backup beside the database, whatever schema it holds.
    static func existingBackups(for database: URL) throws -> [URL] {
        let prefix = database.lastPathComponent + ".schema-v"
        return try files(beside: database) { $0.hasPrefix(prefix) && $0.hasSuffix(".sqlite3") }
    }

    /// Choosing not to keep expired history also drops the copies at once.
    /// With unlimited full-detail history nothing expires, so only the
    /// 14-day limit applies.
    static func discardsAll(rawWindow: TimeInterval?, rollupBucketSeconds: Int?) -> Bool {
        rawWindow != nil && !(rollupBucketSeconds.map { $0 > 0 } ?? false)
    }

    /// SQLite's backup API includes committed WAL pages. Keep the pre-upgrade
    /// database for an explicit rollback; never replace an existing backup.
    static func preserveBeforeUpgrade(_ database: OpaquePointer, at url: URL, schemaVersion: Int) throws {
        let hasHistory = try SQLiteStatement.querySingleInt64(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'telemetry_samples';",
            using: database, operation: "inspect history before backup"
        ) { _ in } ?? 0
        guard hasHistory > 0 else { return }
        let destination = Self.url(for: url, schemaVersion: schemaVersion)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(temporaryPrefix + UUID().uuidString)
        // The copy briefly runs in WAL mode, so SQLite may leave -wal/-shm
        // files named after the temporary file.
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: temporary.path + suffix)
            }
        }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw HistoryStoreError.invalidConfiguration("Cannot create private history backup file")
        }
        var output: OpaquePointer?
        let opened = sqlite3_open_v2(temporary.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard opened == SQLITE_OK, let connection = output else {
            if let output { sqlite3_close(output) }
            throw HistoryStoreError.invalidConfiguration("Cannot create pre-upgrade history backup")
        }
        defer { if let output { sqlite3_close(output) } }
        guard let backup = sqlite3_backup_init(connection, "main", database, "main") else {
            throw SQLiteStatement.error(operation: "initialize history backup", result: sqlite3_errcode(connection), using: connection)
        }
        let copied = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard copied == SQLITE_DONE, finished == SQLITE_OK else {
            throw SQLiteStatement.error(operation: "copy history backup", result: finished == SQLITE_OK ? copied : finished, using: connection)
        }
        // Finish/checkpoint the destination before renaming it. A backup of a
        // WAL database must be readable as one standalone file.
        try SQLiteStatement.execute("PRAGMA journal_mode=DELETE;", using: connection, operation: "finalize history backup")
        let closed = sqlite3_close(connection)
        guard closed == SQLITE_OK else {
            throw HistoryStoreError.invalidConfiguration("Cannot close pre-upgrade history backup")
        }
        output = nil
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// Removes copies older than `retention`, or all of them when the user
    /// chose not to keep expired history. A copy whose age is unknown is
    /// treated as expired. Files left by an interrupted backup go too.
    static func removeExpired(at url: URL, now: Date, discardingAll: Bool) throws {
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else {
            return
        }
        for leftover in try files(beside: url, matching: { $0.hasPrefix(temporaryPrefix) }) {
            try FileManager.default.removeItem(at: leftover)
        }
        for backup in try existingBackups(for: url) {
            let created = try FileManager.default.attributesOfItem(atPath: backup.path)[.creationDate] as? Date
            let expired = created.map { now.timeIntervalSince($0) >= retention } ?? true
            if discardingAll || expired {
                try FileManager.default.removeItem(at: backup)
            }
        }
    }

    private static func files(beside database: URL, matching include: (String) -> Bool) throws -> [URL] {
        let directory = database.deletingLastPathComponent()
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter(include)
            .map { directory.appendingPathComponent($0) }
    }
}
