import Foundation
import SQLite3

actor HistoryStore: HistoryStoring {
    private let databaseURL: URL

    init(databaseURL: URL? = nil) {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appDirectory = supportDirectory.appendingPathComponent("PowerLens", isDirectory: true)
            self.databaseURL = appDirectory.appendingPathComponent("history.sqlite3")
        }
    }

    func loadRecent(
        since cutoffDate: Date
    ) async throws -> [TelemetrySnapshot] {
        let db = try openDatabase()

        defer {
            sqlite3_close(db)
        }

        let sql = """
        SELECT
            s.ts,
            s.power_source_code,
            s.thermal_state_code,
            s.is_charging,
            s.is_charged,
            s.external_connected,
            s.low_power_mode_enabled,
            s.battery_level_x10,
            s.time_to_empty_minutes,
            s.time_to_full_minutes,
            s.battery_temperature_c_x100,
            s.battery_voltage_mv,
            s.battery_current_ma,
            s.battery_power_mw,
            s.adapter_input_power_mw,
            s.adapter_voltage_mv,
            s.adapter_current_ma,
            s.system_load_mw,
            b.serial_number,
            b.design_capacity_mah,
            b.design_cycle_count,
            bs.full_charge_capacity_mah,
            bs.nominal_capacity_mah,
            bs.cycle_count,
            bs.battery_health_text,
            bs.battery_health_condition,
            a.description,
            a.max_power_mw,
            ap.bundle_identifier,
            ap.display_name,
            s.battery_power_source_code
        FROM telemetry_samples s
        LEFT JOIN batteries b ON b.battery_id = s.battery_id
        LEFT JOIN battery_states bs ON bs.battery_state_id = s.battery_state_id
        LEFT JOIN adapters a ON a.adapter_id = s.adapter_id
        LEFT JOIN apps ap ON ap.app_id = s.app_id
        WHERE s.ts >= ?
        ORDER BY s.ts ASC
        """

        let statement = try SQLiteStatement.prepare(
            sql,
            using: db,
            operation: "load recent history"
        )

        defer {
            sqlite3_finalize(statement)
        }

        sqlite3_bind_int64(statement, 1, sqlite3_int64(cutoffDate.timeIntervalSince1970.rounded()))

        var snapshots: [TelemetrySnapshot] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let snapshot = snapshot(from: statement) {
                snapshots.append(snapshot)
            }
            result = sqlite3_step(statement)
        }
        try SQLiteStatement.requireDone(
            result,
            using: db,
            operation: "load recent history"
        )

        return snapshots
    }

    func append(_ snapshot: TelemetrySnapshot) async throws {
        let db = try openDatabase()

        defer {
            sqlite3_close(db)
        }

        try SQLiteStatement.execute(
            "BEGIN IMMEDIATE TRANSACTION;",
            using: db,
            operation: "begin history append"
        )

        let timestamp = Int64(snapshot.timestamp.timeIntervalSince1970.rounded())
        do {
            let batteryID = try upsertBattery(snapshot: snapshot, timestamp: timestamp, using: db)
            let batteryStateID = try upsertBatteryState(snapshot: snapshot, batteryID: batteryID, timestamp: timestamp, using: db)
            let adapterID = try upsertAdapter(snapshot: snapshot, timestamp: timestamp, using: db)
            let appID = try upsertApp(snapshot: snapshot, timestamp: timestamp, using: db)

            try insertSample(
                snapshot: snapshot,
                timestamp: timestamp,
                batteryID: batteryID,
                batteryStateID: batteryStateID,
                adapterID: adapterID,
                appID: appID,
                using: db
            )

            try SQLiteStatement.execute(
                "COMMIT;",
                using: db,
                operation: "commit history append"
            )
        } catch {
            try? SQLiteStatement.execute(
                "ROLLBACK;",
                using: db,
                operation: "roll back history append"
            )
            throw error
        }
    }

    func purge(
        olderThan cutoffDate: Date,
        rollupBucketSeconds: Int?
    ) async throws {
        let db = try openDatabase()

        defer {
            sqlite3_close(db)
        }

        let cutoff = Int64(cutoffDate.timeIntervalSince1970.rounded())
        let retainsBatteryHealth = rollupBucketSeconds.map { $0 > 0 } ?? false

        try SQLiteStatement.execute(
            "BEGIN IMMEDIATE TRANSACTION;",
            using: db,
            operation: "begin history purge"
        )
        do {
            if let bucketSeconds = rollupBucketSeconds, bucketSeconds > 0 {
                // Only roll up and delete buckets that are fully older than the
                // cutoff so a straddling bucket is never split across two runs.
                let effectiveCutoff =
                    (cutoff / Int64(bucketSeconds)) * Int64(bucketSeconds)
                try rollUpSamples(before: effectiveCutoff, bucketSeconds: bucketSeconds, using: db)
                try SQLiteStatement.executePrepared(
                    "DELETE FROM telemetry_samples WHERE ts < ?",
                    using: db,
                    operation: "delete rolled-up samples"
                ) { statement in
                    sqlite3_bind_int64(statement, 1, effectiveCutoff)
                }
            } else {
                // Long-term resolution is off: discard old samples without
                // downsampling, including rollups from a previous setting.
                try SQLiteStatement.executePrepared(
                    "DELETE FROM telemetry_samples WHERE ts < ?",
                    using: db,
                    operation: "delete expired samples"
                ) { statement in
                    sqlite3_bind_int64(statement, 1, cutoff)
                }
                try SQLiteStatement.executePrepared(
                    "DELETE FROM history_rollups WHERE bucket_start < ?",
                    using: db,
                    operation: "delete expired rollups"
                ) { statement in
                    sqlite3_bind_int64(statement, 1, cutoff)
                }
            }

            try purgeOrphanedReferences(
                retainingBatteryHealth: retainsBatteryHealth,
                using: db
            )
            try SQLiteStatement.execute(
                "COMMIT;",
                using: db,
                operation: "commit history purge"
            )
        } catch {
            try? SQLiteStatement.execute(
                "ROLLBACK;",
                using: db,
                operation: "roll back history purge"
            )
            throw error
        }

        // Reclaim freed pages when incremental auto-vacuum is enabled. This is a
        // no-op on databases created before auto-vacuum was enabled, and on
        // those the file simply stops growing rather than shrinking.
        try SQLiteStatement.execute(
            "PRAGMA incremental_vacuum;",
            using: db,
            operation: "reclaim history pages"
        )
    }

    private func purgeOrphanedReferences(
        retainingBatteryHealth: Bool,
        using db: OpaquePointer
    ) throws {
        try SQLiteStatement.execute(
            """
            DELETE FROM apps
            WHERE NOT EXISTS (
                SELECT 1
                FROM telemetry_samples
                WHERE telemetry_samples.app_id = apps.app_id
            );
            """,
            using: db,
            operation: "delete unreferenced apps"
        )
        try SQLiteStatement.execute(
            """
            DELETE FROM adapters
            WHERE NOT EXISTS (
                SELECT 1
                FROM telemetry_samples
                WHERE telemetry_samples.adapter_id = adapters.adapter_id
            );
            """,
            using: db,
            operation: "delete unreferenced adapters"
        )

        guard !retainingBatteryHealth else {
            return
        }

        try SQLiteStatement.execute(
            """
            DELETE FROM battery_states
            WHERE NOT EXISTS (
                SELECT 1
                FROM telemetry_samples
                WHERE telemetry_samples.battery_state_id =
                    battery_states.battery_state_id
            );
            """,
            using: db,
            operation: "delete unreferenced battery states"
        )
        try SQLiteStatement.execute(
            """
            DELETE FROM batteries
            WHERE NOT EXISTS (
                SELECT 1
                FROM telemetry_samples
                WHERE telemetry_samples.battery_id = batteries.battery_id
            )
            AND NOT EXISTS (
                SELECT 1
                FROM battery_states
                WHERE battery_states.battery_id = batteries.battery_id
            );
            """,
            using: db,
            operation: "delete unreferenced batteries"
        )
    }

    private func rollUpSamples(before cutoff: Int64, bucketSeconds: Int, using db: OpaquePointer) throws {
        // Each bucket counts its own rising charging edges, including an
        // already-charging first observation. Stored boundary states let the
        // summary join these segments without double-counting one session.
        // Duration estimates retain the nominal one-minute sampling interval.
        let sql = """
        WITH bucketed AS (
            SELECT *, (ts / ?1) * ?1 AS bucket
            FROM telemetry_samples
            WHERE ts < ?2
        ), ordered AS (
            SELECT *,
                LAG(is_charging) OVER (
                    PARTITION BY bucket ORDER BY ts, sample_id
                ) AS previous_charging,
                ROW_NUMBER() OVER (
                    PARTITION BY bucket ORDER BY ts, sample_id
                ) AS first_position,
                ROW_NUMBER() OVER (
                    PARTITION BY bucket ORDER BY ts DESC, sample_id DESC
                ) AS last_position
            FROM bucketed
        )
        INSERT INTO history_rollups (
            bucket_start,
            bucket_seconds,
            sample_count,
            battery_level_avg_x10,
            battery_level_min_x10,
            battery_level_max_x10,
            adapter_input_power_avg_mw,
            system_load_avg_mw,
            system_load_max_mw,
            battery_power_avg_mw,
            battery_temperature_avg_c_x100,
            battery_temperature_max_c_x100,
            on_battery_seconds,
            on_external_seconds,
            charge_sessions,
            system_load_sum_mw,
            system_load_count,
            adapter_input_power_sum_mw,
            adapter_input_power_count,
            battery_temperature_sum_c_x100,
            battery_temperature_count,
            first_sample_ts,
            first_is_charging,
            last_is_charging
        )
        SELECT
            bucket,
            ?1,
            COUNT(*),
            CAST(ROUND(AVG(battery_level_x10)) AS INTEGER),
            MIN(battery_level_x10),
            MAX(battery_level_x10),
            CAST(ROUND(AVG(adapter_input_power_mw)) AS INTEGER),
            CAST(ROUND(AVG(system_load_mw)) AS INTEGER),
            MAX(system_load_mw),
            CAST(ROUND(AVG(battery_power_mw)) AS INTEGER),
            CAST(ROUND(AVG(battery_temperature_c_x100)) AS INTEGER),
            MAX(battery_temperature_c_x100),
            SUM(CASE WHEN external_connected = 0 THEN 60 ELSE 0 END),
            SUM(CASE WHEN external_connected = 1 THEN 60 ELSE 0 END),
            SUM(CASE WHEN is_charging = 1
                     AND COALESCE(previous_charging, 0) = 0 THEN 1 ELSE 0 END),
            SUM(system_load_mw),
            COUNT(system_load_mw),
            SUM(adapter_input_power_mw),
            COUNT(adapter_input_power_mw),
            SUM(battery_temperature_c_x100),
            COUNT(battery_temperature_c_x100),
            MIN(ts),
            MAX(CASE WHEN first_position = 1 THEN is_charging END),
            MAX(CASE WHEN last_position = 1 THEN is_charging END)
        FROM ordered
        GROUP BY bucket
        """

        try SQLiteStatement.executePrepared(
            sql,
            using: db,
            operation: "roll up history samples"
        ) { statement in
            let bucket = sqlite3_int64(bucketSeconds)
            sqlite3_bind_int64(statement, 1, bucket)
            sqlite3_bind_int64(statement, 2, cutoff)
        }
    }

    func aggregatedSeries(
        for range: DateInterval,
        bucketSeconds: Int
    ) throws -> [AggregatedTelemetryPoint] {
        guard bucketSeconds > 0 else {
            throw HistoryStoreError.invalidConfiguration(
                "History bucket duration must be greater than zero."
            )
        }
        let db = try openDatabase()

        defer {
            sqlite3_close(db)
        }

        let sql = """
        SELECT
            (ts / ?) * ? AS bucket_start,
            AVG(battery_level_x10),
            MIN(battery_level_x10),
            MAX(battery_level_x10),
            AVG(adapter_input_power_mw),
            AVG(system_load_mw),
            MAX(system_load_mw),
            AVG(battery_power_mw),
            AVG(battery_temperature_c_x100),
            MAX(battery_temperature_c_x100),
            COUNT(*)
        FROM telemetry_samples
        WHERE ts >= ? AND ts < ?
        GROUP BY bucket_start
        ORDER BY bucket_start ASC
        """

        let statement = try SQLiteStatement.prepare(
            sql,
            using: db,
            operation: "load aggregated history"
        )

        defer {
            sqlite3_finalize(statement)
        }

        let bucket = sqlite3_int64(bucketSeconds)
        sqlite3_bind_int64(statement, 1, bucket)
        sqlite3_bind_int64(statement, 2, bucket)
        sqlite3_bind_int64(statement, 3, Int64(range.start.timeIntervalSince1970.rounded()))
        sqlite3_bind_int64(statement, 4, Int64(range.end.timeIntervalSince1970.rounded()))

        var points: [AggregatedTelemetryPoint] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let bucketStart = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0)))
            points.append(
                AggregatedTelemetryPoint(
                    bucketStart: bucketStart,
                    avgBatteryLevel: SQLiteStatement.optionalDoubleValue(statement, index: 1).map { $0 / 10 },
                    minBatteryLevel: SQLiteStatement.optionalDoubleValue(statement, index: 2).map { $0 / 10 },
                    maxBatteryLevel: SQLiteStatement.optionalDoubleValue(statement, index: 3).map { $0 / 10 },
                    avgAdapterInputPowerW: SQLiteStatement.optionalDoubleValue(statement, index: 4).map { $0 / 1000 },
                    avgSystemLoadW: SQLiteStatement.optionalDoubleValue(statement, index: 5).map { $0 / 1000 },
                    maxSystemLoadW: SQLiteStatement.optionalDoubleValue(statement, index: 6).map { $0 / 1000 },
                    avgBatteryPowerW: SQLiteStatement.optionalDoubleValue(statement, index: 7).map { $0 / 1000 },
                    avgTemperatureC: SQLiteStatement.optionalDoubleValue(statement, index: 8).map { $0 / 100 },
                    maxTemperatureC: SQLiteStatement.optionalDoubleValue(statement, index: 9).map { $0 / 100 },
                    sampleCount: Int(sqlite3_column_int64(statement, 10))
                )
            )
            result = sqlite3_step(statement)
        }
        try SQLiteStatement.requireDone(
            result,
            using: db,
            operation: "load aggregated history"
        )

        return points
    }

    func rollupSeries(
        for range: DateInterval
    ) throws -> [AggregatedTelemetryPoint] {
        let db = try openDatabase()

        defer {
            sqlite3_close(db)
        }

        // A resolution change can leave two disjoint sets of observations in
        // buckets with the same nominal start. Use their recorded first sample
        // for plotting; legacy rows keep their original coarse bucket position.
        let sql = """
        SELECT
            COALESCE(first_sample_ts, bucket_start) AS observation_start,
            sample_count,
            battery_level_avg_x10,
            battery_level_min_x10,
            battery_level_max_x10,
            CASE WHEN adapter_input_power_count IS NULL
                 THEN adapter_input_power_avg_mw
                 ELSE 1.0 * adapter_input_power_sum_mw
                      / NULLIF(adapter_input_power_count, 0) END,
            CASE WHEN system_load_count IS NULL THEN system_load_avg_mw
                 ELSE 1.0 * system_load_sum_mw
                      / NULLIF(system_load_count, 0) END,
            system_load_max_mw,
            battery_power_avg_mw,
            CASE WHEN battery_temperature_count IS NULL
                 THEN battery_temperature_avg_c_x100
                 ELSE 1.0 * battery_temperature_sum_c_x100
                      / NULLIF(battery_temperature_count, 0) END,
            battery_temperature_max_c_x100
        FROM history_rollups
        WHERE bucket_start >= ? AND bucket_start < ?
        ORDER BY observation_start ASC, bucket_seconds ASC
        """

        let statement = try SQLiteStatement.prepare(
            sql,
            using: db,
            operation: "load rolled-up history"
        )

        defer {
            sqlite3_finalize(statement)
        }

        sqlite3_bind_int64(statement, 1, Int64(range.start.timeIntervalSince1970.rounded()))
        sqlite3_bind_int64(statement, 2, Int64(range.end.timeIntervalSince1970.rounded()))

        var points: [AggregatedTelemetryPoint] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            points.append(
                AggregatedTelemetryPoint(
                    bucketStart: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                    avgBatteryLevel: SQLiteStatement.optionalDoubleValue(statement, index: 2).map { $0 / 10 },
                    minBatteryLevel: SQLiteStatement.optionalDoubleValue(statement, index: 3).map { $0 / 10 },
                    maxBatteryLevel: SQLiteStatement.optionalDoubleValue(statement, index: 4).map { $0 / 10 },
                    avgAdapterInputPowerW: SQLiteStatement.optionalDoubleValue(statement, index: 5).map { $0 / 1000 },
                    avgSystemLoadW: SQLiteStatement.optionalDoubleValue(statement, index: 6).map { $0 / 1000 },
                    maxSystemLoadW: SQLiteStatement.optionalDoubleValue(statement, index: 7).map { $0 / 1000 },
                    avgBatteryPowerW: SQLiteStatement.optionalDoubleValue(statement, index: 8).map { $0 / 1000 },
                    avgTemperatureC: SQLiteStatement.optionalDoubleValue(statement, index: 9).map { $0 / 100 },
                    maxTemperatureC: SQLiteStatement.optionalDoubleValue(statement, index: 10).map { $0 / 100 },
                    sampleCount: Int(sqlite3_column_int64(statement, 1))
                )
            )
            result = sqlite3_step(statement)
        }
        try SQLiteStatement.requireDone(
            result,
            using: db,
            operation: "load rolled-up history"
        )

        return points
    }

    func batteryHealthTrend(
        since cutoffDate: Date
    ) throws -> [BatteryHealthPoint] {
        let db = try openDatabase()

        defer {
            sqlite3_close(db)
        }

        let sql = """
        SELECT
            bs.first_seen_ts,
            bs.full_charge_capacity_mah,
            bs.nominal_capacity_mah,
            bs.cycle_count,
            b.design_capacity_mah
        FROM battery_states bs
        JOIN batteries b ON b.battery_id = bs.battery_id
        WHERE bs.first_seen_ts >= ?
        ORDER BY bs.first_seen_ts ASC
        """

        let statement = try SQLiteStatement.prepare(
            sql,
            using: db,
            operation: "load battery-health trend"
        )

        defer {
            sqlite3_finalize(statement)
        }

        sqlite3_bind_int64(statement, 1, Int64(cutoffDate.timeIntervalSince1970.rounded()))

        var points: [BatteryHealthPoint] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            points.append(
                BatteryHealthPoint(
                    date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                    fullChargeCapacityMah: SQLiteStatement.optionalIntValue(statement, index: 1),
                    designCapacityMah: SQLiteStatement.optionalIntValue(statement, index: 4),
                    nominalCapacityMah: SQLiteStatement.optionalIntValue(statement, index: 2),
                    cycleCount: SQLiteStatement.optionalIntValue(statement, index: 3)
                )
            )
            result = sqlite3_step(statement)
        }
        try SQLiteStatement.requireDone(
            result,
            using: db,
            operation: "load battery-health trend"
        )

        return points
    }

    func summary(for range: DateInterval) throws -> HistorySummary {
        let db = try openDatabase()

        defer {
            sqlite3_close(db)
        }

        let sql = """
        SELECT
            ts,
            external_connected,
            is_charging,
            system_load_mw,
            adapter_input_power_mw,
            battery_temperature_c_x100,
            battery_level_x10
        FROM telemetry_samples
        WHERE ts >= ? AND ts < ?
        ORDER BY ts ASC, sample_id ASC
        """

        let statement = try SQLiteStatement.prepare(
            sql,
            using: db,
            operation: "load history summary"
        )

        defer {
            sqlite3_finalize(statement)
        }

        sqlite3_bind_int64(statement, 1, Int64(range.start.timeIntervalSince1970.rounded()))
        sqlite3_bind_int64(statement, 2, Int64(range.end.timeIntervalSince1970.rounded()))

        // Cap inter-sample gaps so sleep/quit periods do not inflate the on-battery
        // and on-external totals. The persistence cadence is roughly one sample a
        // minute, so a 10-minute cap tolerates brief stalls without overcounting.
        let maxGap: TimeInterval = 600
        var sampleCount = 0
        var loadSum = 0.0
        var loadSamples = 0
        var loadMax: Double?
        var inputSum = 0.0
        var inputSamples = 0
        var tempSum = 0.0
        var tempSamples = 0
        var tempMax: Double?
        var levelMin: Double?
        var levelMax: Double?
        var timeOnBattery: TimeInterval = 0
        var timeOnExternal: TimeInterval = 0
        var chargeSessions = 0

        var previousTimestamp: TimeInterval?
        var previousExternal = false
        var previousCharging = false
        var firstTimestamp: Int64?
        var firstCharging: Bool?

        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            sampleCount += 1
            let timestamp = TimeInterval(sqlite3_column_int64(statement, 0))
            let external = sqlite3_column_int(statement, 1) == 1
            let charging = sqlite3_column_int(statement, 2) == 1
            if firstTimestamp == nil {
                firstTimestamp = sqlite3_column_int64(statement, 0)
                firstCharging = charging
            }

            if let loadMW = SQLiteStatement.optionalDoubleValue(statement, index: 3) {
                let load = loadMW / 1000
                loadSum += load
                loadSamples += 1
                loadMax = Swift.max(loadMax ?? load, load)
            }

            if let inputMW = SQLiteStatement.optionalDoubleValue(statement, index: 4) {
                inputSum += inputMW / 1000
                inputSamples += 1
            }

            if let tempHundredths = SQLiteStatement.optionalDoubleValue(statement, index: 5) {
                let temperature = tempHundredths / 100
                tempSum += temperature
                tempSamples += 1
                tempMax = Swift.max(tempMax ?? temperature, temperature)
            }

            if let levelTenths = SQLiteStatement.optionalDoubleValue(statement, index: 6) {
                let level = levelTenths / 10
                levelMin = Swift.min(levelMin ?? level, level)
                levelMax = Swift.max(levelMax ?? level, level)
            }

            if let previousTimestamp {
                let gap = Swift.min(timestamp - previousTimestamp, maxGap)
                if gap > 0 {
                    if previousExternal {
                        timeOnExternal += gap
                    } else {
                        timeOnBattery += gap
                    }
                }
            }

            if charging, !previousCharging {
                chargeSessions += 1
            }

            previousTimestamp = timestamp
            previousExternal = external
            previousCharging = charging
            result = sqlite3_step(statement)
        }
        try SQLiteStatement.requireDone(
            result,
            using: db,
            operation: "load history summary"
        )

        // New rollups retain exact sums and per-sensor valid-value counts.
        // Legacy rows retain their historical sample-weighted estimate because
        // missing-value counts cannot be recovered after raw data was removed.
        let rollupSQL = """
        SELECT
            COALESCE(SUM(sample_count), 0),
            SUM(CASE WHEN system_load_count IS NULL
                     THEN system_load_avg_mw * sample_count
                     ELSE system_load_sum_mw END),
            SUM(COALESCE(system_load_count,
                CASE WHEN system_load_avg_mw IS NOT NULL THEN sample_count ELSE 0 END)),
            MAX(system_load_max_mw),
            SUM(CASE WHEN adapter_input_power_count IS NULL
                     THEN adapter_input_power_avg_mw * sample_count
                     ELSE adapter_input_power_sum_mw END),
            SUM(COALESCE(adapter_input_power_count,
                CASE WHEN adapter_input_power_avg_mw IS NOT NULL THEN sample_count ELSE 0 END)),
            SUM(CASE WHEN battery_temperature_count IS NULL
                     THEN battery_temperature_avg_c_x100 * sample_count
                     ELSE battery_temperature_sum_c_x100 END),
            SUM(COALESCE(battery_temperature_count,
                CASE WHEN battery_temperature_avg_c_x100 IS NOT NULL THEN sample_count ELSE 0 END)),
            MAX(battery_temperature_max_c_x100),
            MIN(battery_level_min_x10),
            MAX(battery_level_max_x10),
            COALESCE(SUM(on_battery_seconds), 0),
            COALESCE(SUM(on_external_seconds), 0)
        FROM history_rollups
        WHERE bucket_start >= ? AND bucket_start < ?
        """

        let rollupStatement = try SQLiteStatement.prepare(
            rollupSQL,
            using: db,
            operation: "load rolled-up history summary"
        )
        defer {
            sqlite3_finalize(rollupStatement)
        }
        sqlite3_bind_int64(rollupStatement, 1, Int64(range.start.timeIntervalSince1970.rounded()))
        sqlite3_bind_int64(rollupStatement, 2, Int64(range.end.timeIntervalSince1970.rounded()))

        let rollupResult = sqlite3_step(rollupStatement)
        guard rollupResult == SQLITE_ROW else {
            try SQLiteStatement.requireDone(
                rollupResult,
                using: db,
                operation: "load rolled-up history summary"
            )
            return .empty(range: range)
        }

        let rollupCount = Int(sqlite3_column_int64(rollupStatement, 0))
        if rollupCount > 0 {
            sampleCount += rollupCount

            if let loadSumMilliwatts = SQLiteStatement.optionalDoubleValue(rollupStatement, index: 1) {
                loadSum += loadSumMilliwatts / 1000
            }
            loadSamples += Int(sqlite3_column_int64(rollupStatement, 2))
            if let loadMaxMilliwatts = SQLiteStatement.optionalDoubleValue(rollupStatement, index: 3) {
                let value = loadMaxMilliwatts / 1000
                loadMax = Swift.max(loadMax ?? value, value)
            }

            if let inputSumMilliwatts = SQLiteStatement.optionalDoubleValue(rollupStatement, index: 4) {
                inputSum += inputSumMilliwatts / 1000
            }
            inputSamples += Int(sqlite3_column_int64(rollupStatement, 5))

            if let tempSumHundredths = SQLiteStatement.optionalDoubleValue(rollupStatement, index: 6) {
                tempSum += tempSumHundredths / 100
            }
            tempSamples += Int(sqlite3_column_int64(rollupStatement, 7))
            if let tempMaxHundredths = SQLiteStatement.optionalDoubleValue(rollupStatement, index: 8) {
                let value = tempMaxHundredths / 100
                tempMax = Swift.max(tempMax ?? value, value)
            }

            if let levelMinTenths = SQLiteStatement.optionalDoubleValue(rollupStatement, index: 9) {
                let value = levelMinTenths / 10
                levelMin = Swift.min(levelMin ?? value, value)
            }
            if let levelMaxTenths = SQLiteStatement.optionalDoubleValue(rollupStatement, index: 10) {
                let value = levelMaxTenths / 10
                levelMax = Swift.max(levelMax ?? value, value)
            }

            timeOnBattery += Double(sqlite3_column_int64(rollupStatement, 11))
            timeOnExternal += Double(sqlite3_column_int64(rollupStatement, 12))
        }

        guard sampleCount > 0 else {
            return .empty(range: range)
        }

        let combinedChargeSessions = try mergedChargeSessions(
            for: range,
            rawFirstTimestamp: firstTimestamp,
            rawFirstCharging: firstCharging,
            rawLastCharging: previousCharging,
            rawChargeSessions: chargeSessions,
            using: db
        )

        return HistorySummary(
            range: range,
            sampleCount: sampleCount,
            avgSystemLoadW: loadSamples > 0 ? loadSum / Double(loadSamples) : nil,
            maxSystemLoadW: loadMax,
            avgAdapterInputPowerW: inputSamples > 0 ? inputSum / Double(inputSamples) : nil,
            avgTemperatureC: tempSamples > 0 ? tempSum / Double(tempSamples) : nil,
            maxTemperatureC: tempMax,
            minBatteryLevel: levelMin,
            maxBatteryLevel: levelMax,
            timeOnBattery: timeOnBattery,
            timeOnExternal: timeOnExternal,
            chargeSessions: combinedChargeSessions
        )
    }

    private func mergedChargeSessions(
        for range: DateInterval,
        rawFirstTimestamp: Int64?,
        rawFirstCharging: Bool?,
        rawLastCharging: Bool,
        rawChargeSessions: Int,
        using db: OpaquePointer
    ) throws -> Int {
        // Raw data is the contiguous retained tail, so its already-computed
        // sessions form one segment. New rollups each form another segment.
        // A NULL legacy boundary deliberately breaks continuity: the original
        // estimate is preserved rather than guessing a missing charging state.
        let sql = """
        WITH segments AS (
            SELECT COALESCE(first_sample_ts, bucket_start) AS first_ts,
                   bucket_seconds,
                   COALESCE(charge_sessions, 0) AS sessions,
                   first_is_charging AS first_charging,
                   last_is_charging AS last_charging
            FROM history_rollups
            WHERE bucket_start >= ?1 AND bucket_start < ?2
            UNION ALL
            SELECT ?3, 0, ?4, ?5, ?6 WHERE ?3 IS NOT NULL
        ), connected AS (
            SELECT sessions, first_charging,
                   LAG(last_charging) OVER (
                       ORDER BY first_ts, bucket_seconds
                   ) AS previous_last_charging
            FROM segments
        )
        SELECT COALESCE(SUM(sessions - CASE
            WHEN first_charging = 1 AND previous_last_charging = 1 THEN 1
            ELSE 0 END), 0)
        FROM connected
        """
        return Int(try SQLiteStatement.querySingleInt64(
            sql,
            using: db,
            operation: "join history charging sessions"
        ) { statement in
            sqlite3_bind_int64(statement, 1, Int64(range.start.timeIntervalSince1970.rounded()))
            sqlite3_bind_int64(statement, 2, Int64(range.end.timeIntervalSince1970.rounded()))
            SQLiteStatement.bind(rawFirstTimestamp, to: statement, index: 3)
            SQLiteStatement.bind(rawChargeSessions, to: statement, index: 4)
            SQLiteStatement.bind(rawFirstCharging.map { $0 ? 1 : 0 }, to: statement, index: 5)
            sqlite3_bind_int(statement, 6, rawLastCharging ? 1 : 0)
        } ?? 0)
    }

    /// No suspension occurs between these queries, so append/purge operations
    /// on this actor cannot split one Insights result across retention states.
    func loadInsights(for range: HistoryRange, now: Date) async throws -> InsightsData {
        let interval = range.interval(now: now)
        var rawSeries = try aggregatedSeries(
            for: interval,
            bucketSeconds: range.bucketSeconds
        )
        let rollups = try rollupSeries(for: interval)

        // The first raw aggregation bucket may start before its first retained
        // sample, at the same x coordinate as an older rollup. Keep its metrics
        // intact and place this boundary point at the first actual raw sample.
        if let first = rawSeries.first,
           let timestamp = try firstRawTimestamp(in: interval),
           timestamp > first.bucketStart {
            rawSeries[0] = AggregatedTelemetryPoint(
                bucketStart: timestamp,
                avgBatteryLevel: first.avgBatteryLevel,
                minBatteryLevel: first.minBatteryLevel,
                maxBatteryLevel: first.maxBatteryLevel,
                avgAdapterInputPowerW: first.avgAdapterInputPowerW,
                avgSystemLoadW: first.avgSystemLoadW,
                maxSystemLoadW: first.maxSystemLoadW,
                avgBatteryPowerW: first.avgBatteryPowerW,
                avgTemperatureC: first.avgTemperatureC,
                maxTemperatureC: first.maxTemperatureC,
                sampleCount: first.sampleCount
            )
        }

        return InsightsData(
            range: range,
            interval: interval,
            series: (rollups + rawSeries).sorted { $0.bucketStart < $1.bucketStart },
            summary: try summary(for: interval),
            healthTrend: try batteryHealthTrend(since: Date(timeIntervalSince1970: 0))
        )
    }

    private func firstRawTimestamp(in range: DateInterval) throws -> Date? {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let timestamp = try SQLiteStatement.querySingleInt64(
            "SELECT ts FROM telemetry_samples WHERE ts >= ? AND ts < ? ORDER BY ts LIMIT 1;",
            using: db,
            operation: "locate retained history boundary"
        ) { statement in
            sqlite3_bind_int64(statement, 1, Int64(range.start.timeIntervalSince1970.rounded()))
            sqlite3_bind_int64(statement, 2, Int64(range.end.timeIntervalSince1970.rounded()))
        }
        return timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    private func openDatabase() throws -> OpaquePointer {
        let directory = databaseURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw HistoryStoreError.fileSystem(
                operation: "Create history directory",
                description: error.localizedDescription
            )
        }

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let db else {
            let message: String
            if let db {
                message = String(cString: sqlite3_errmsg(db))
                sqlite3_close(db)
            } else {
                message = String(cString: sqlite3_errstr(openResult))
            }
            throw HistoryStoreError.sqlite(
                operation: "Open history database",
                code: openResult,
                message: message
            )
        }

        sqlite3_extended_result_codes(db, 1)

        do {
            try SQLiteStatement.execute(
                "PRAGMA journal_mode=WAL;",
                using: db,
                operation: "Enable history WAL"
            )
            try SQLiteStatement.execute(
                "PRAGMA synchronous=NORMAL;",
                using: db,
                operation: "Configure history synchronization"
            )
            try SQLiteStatement.execute(
                "PRAGMA foreign_keys=ON;",
                using: db,
                operation: "Enable history foreign keys"
            )
            try SQLiteStatement.execute(
                "PRAGMA auto_vacuum=INCREMENTAL;",
                using: db,
                operation: "Configure history vacuum"
            )
            let schemaVersion = try schemaVersion(using: db)
            guard schemaVersion <= HistorySchema.currentVersion else {
                throw HistoryStoreError.invalidConfiguration(
                    "History database schema \(schemaVersion) is newer than this PowerLens build supports."
                )
            }
            if schemaVersion < HistorySchema.currentVersion {
                try migrateSchema(using: db)
            }
        } catch {
            sqlite3_close(db)
            throw error
        }

        return db
    }

    private func schemaVersion(using db: OpaquePointer) throws -> Int {
        Int(
            try SQLiteStatement.querySingleInt64(
                "PRAGMA user_version;",
                using: db,
                operation: "read history schema version"
            ) { _ in } ?? 0
        )
    }

    private func migrateSchema(using db: OpaquePointer) throws {
        try SQLiteStatement.execute(
            "BEGIN IMMEDIATE TRANSACTION;",
            using: db,
            operation: "begin history migration"
        )

        do {
            for statement in HistorySchema.creationStatements {
                try SQLiteStatement.execute(
                    statement,
                    using: db,
                    operation: "create history schema"
                )
            }

            for migration in HistorySchema.columnMigrations {
                if try tableHasColumn(
                    migration.column,
                    in: migration.table,
                    using: db
                ) {
                    continue
                }
                try SQLiteStatement.execute(
                    migration.sql,
                    using: db,
                    operation: "migrate history schema"
                )
            }

            try SQLiteStatement.execute(
                "PRAGMA user_version = \(HistorySchema.currentVersion);",
                using: db,
                operation: "record history schema version"
            )
            try SQLiteStatement.execute(
                "COMMIT;",
                using: db,
                operation: "commit history migration"
            )
        } catch {
            try? SQLiteStatement.execute(
                "ROLLBACK;",
                using: db,
                operation: "roll back history migration"
            )
            throw error
        }
    }

    private func tableHasColumn(
        _ column: String,
        in table: String,
        using db: OpaquePointer
    ) throws -> Bool {
        try SQLiteStatement.querySingleInt64(
            """
            SELECT 1
            FROM pragma_table_info(?)
            WHERE name = ?
            LIMIT 1
            """,
            using: db,
            operation: "inspect history schema"
        ) { statement in
            SQLiteStatement.bind(table, to: statement, index: 1)
            SQLiteStatement.bind(column, to: statement, index: 2)
        } != nil
    }

    private func upsertBattery(snapshot: TelemetrySnapshot, timestamp: Int64, using db: OpaquePointer) throws -> Int64? {
        guard snapshot.serialNumber != nil || snapshot.designCapacityMah != nil || snapshot.designCycleCount != nil else {
            return nil
        }

        let batteryKey = snapshot.serialNumber ?? "builtin-battery"
        let sql = """
        INSERT INTO batteries (
            battery_key,
            serial_number,
            design_capacity_mah,
            design_cycle_count,
            first_seen_ts,
            last_seen_ts
        ) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(battery_key) DO UPDATE SET
            serial_number = COALESCE(excluded.serial_number, batteries.serial_number),
            design_capacity_mah = COALESCE(excluded.design_capacity_mah, batteries.design_capacity_mah),
            design_cycle_count = COALESCE(excluded.design_cycle_count, batteries.design_cycle_count),
            last_seen_ts = excluded.last_seen_ts
        """

        try SQLiteStatement.executePrepared(sql, using: db) { statement in
            SQLiteStatement.bind(batteryKey, to: statement, index: 1)
            SQLiteStatement.bind(snapshot.serialNumber, to: statement, index: 2)
            SQLiteStatement.bind(snapshot.designCapacityMah, to: statement, index: 3)
            SQLiteStatement.bind(snapshot.designCycleCount, to: statement, index: 4)
            sqlite3_bind_int64(statement, 5, timestamp)
            sqlite3_bind_int64(statement, 6, timestamp)
        }

        return try SQLiteStatement.querySingleInt64(
            """
            SELECT battery_id FROM batteries WHERE battery_key = ?
            """,
            using: db
        ) { statement in
            SQLiteStatement.bind(batteryKey, to: statement, index: 1)
        }
    }

    private func upsertBatteryState(snapshot: TelemetrySnapshot, batteryID: Int64?, timestamp: Int64, using db: OpaquePointer) throws -> Int64? {
        guard let batteryID else {
            return nil
        }

        let stateKey = [
            String(batteryID),
            HistoryValueCoding.stringComponent(snapshot.fullChargeCapacityMah),
            HistoryValueCoding.stringComponent(snapshot.nominalCapacityMah),
            HistoryValueCoding.stringComponent(snapshot.cycleCount),
            HistoryValueCoding.stringComponent(snapshot.batteryHealthText),
            HistoryValueCoding.stringComponent(snapshot.batteryHealthCondition),
        ].joined(separator: "|")

        let sql = """
        INSERT INTO battery_states (
            battery_id,
            state_key,
            full_charge_capacity_mah,
            nominal_capacity_mah,
            cycle_count,
            battery_health_text,
            battery_health_condition,
            first_seen_ts,
            last_seen_ts
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(state_key) DO UPDATE SET
            last_seen_ts = excluded.last_seen_ts
        """

        try SQLiteStatement.executePrepared(sql, using: db) { statement in
            sqlite3_bind_int64(statement, 1, batteryID)
            SQLiteStatement.bind(stateKey, to: statement, index: 2)
            SQLiteStatement.bind(snapshot.fullChargeCapacityMah, to: statement, index: 3)
            SQLiteStatement.bind(snapshot.nominalCapacityMah, to: statement, index: 4)
            SQLiteStatement.bind(snapshot.cycleCount, to: statement, index: 5)
            SQLiteStatement.bind(snapshot.batteryHealthText, to: statement, index: 6)
            SQLiteStatement.bind(snapshot.batteryHealthCondition, to: statement, index: 7)
            sqlite3_bind_int64(statement, 8, timestamp)
            sqlite3_bind_int64(statement, 9, timestamp)
        }

        return try SQLiteStatement.querySingleInt64(
            """
            SELECT battery_state_id FROM battery_states WHERE state_key = ?
            """,
            using: db
        ) { statement in
            SQLiteStatement.bind(stateKey, to: statement, index: 1)
        }
    }

    private func upsertAdapter(snapshot: TelemetrySnapshot, timestamp: Int64, using db: OpaquePointer) throws -> Int64? {
        guard snapshot.adapterDescription != nil || snapshot.adapterMaxPowerW != nil else {
            return nil
        }

        let maxPowerMW = HistoryValueCoding.milliwatts(from: snapshot.adapterMaxPowerW)
        let adapterKey = [
            HistoryValueCoding.stringComponent(snapshot.adapterDescription),
            HistoryValueCoding.stringComponent(maxPowerMW),
        ].joined(separator: "|")

        let sql = """
        INSERT INTO adapters (
            adapter_key,
            description,
            max_power_mw,
            first_seen_ts,
            last_seen_ts
        ) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(adapter_key) DO UPDATE SET
            description = COALESCE(excluded.description, adapters.description),
            max_power_mw = COALESCE(excluded.max_power_mw, adapters.max_power_mw),
            last_seen_ts = excluded.last_seen_ts
        """

        try SQLiteStatement.executePrepared(sql, using: db) { statement in
            SQLiteStatement.bind(adapterKey, to: statement, index: 1)
            SQLiteStatement.bind(snapshot.adapterDescription, to: statement, index: 2)
            SQLiteStatement.bind(maxPowerMW, to: statement, index: 3)
            sqlite3_bind_int64(statement, 4, timestamp)
            sqlite3_bind_int64(statement, 5, timestamp)
        }

        return try SQLiteStatement.querySingleInt64(
            """
            SELECT adapter_id FROM adapters WHERE adapter_key = ?
            """,
            using: db
        ) { statement in
            SQLiteStatement.bind(adapterKey, to: statement, index: 1)
        }
    }

    private func upsertApp(snapshot: TelemetrySnapshot, timestamp: Int64, using db: OpaquePointer) throws -> Int64? {
        guard snapshot.frontmostAppBundleID != nil || snapshot.frontmostAppName != nil else {
            return nil
        }

        let displayName = snapshot.frontmostAppName ?? snapshot.frontmostAppBundleID ?? "Unknown App"
        let appKey = snapshot.frontmostAppBundleID ?? "name:\(displayName)"

        let sql = """
        INSERT INTO apps (
            app_key,
            bundle_identifier,
            display_name,
            first_seen_ts,
            last_seen_ts
        ) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(app_key) DO UPDATE SET
            bundle_identifier = COALESCE(excluded.bundle_identifier, apps.bundle_identifier),
            display_name = excluded.display_name,
            last_seen_ts = excluded.last_seen_ts
        """

        try SQLiteStatement.executePrepared(sql, using: db) { statement in
            SQLiteStatement.bind(appKey, to: statement, index: 1)
            SQLiteStatement.bind(snapshot.frontmostAppBundleID, to: statement, index: 2)
            SQLiteStatement.bind(displayName, to: statement, index: 3)
            sqlite3_bind_int64(statement, 4, timestamp)
            sqlite3_bind_int64(statement, 5, timestamp)
        }

        return try SQLiteStatement.querySingleInt64(
            """
            SELECT app_id FROM apps WHERE app_key = ?
            """,
            using: db
        ) { statement in
            SQLiteStatement.bind(appKey, to: statement, index: 1)
        }
    }

    private func insertSample(
        snapshot: TelemetrySnapshot,
        timestamp: Int64,
        batteryID: Int64?,
        batteryStateID: Int64?,
        adapterID: Int64?,
        appID: Int64?,
        using db: OpaquePointer
    ) throws {
        let sql = """
        INSERT INTO telemetry_samples (
            ts,
            battery_id,
            battery_state_id,
            adapter_id,
            app_id,
            power_source_code,
            thermal_state_code,
            is_charging,
            is_charged,
            external_connected,
            low_power_mode_enabled,
            battery_level_x10,
            time_to_empty_minutes,
            time_to_full_minutes,
            battery_temperature_c_x100,
            battery_voltage_mv,
            battery_current_ma,
            battery_power_mw,
            adapter_input_power_mw,
            adapter_voltage_mv,
            adapter_current_ma,
            system_load_mw,
            battery_power_source_code
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

        try SQLiteStatement.executePrepared(sql, using: db) { statement in
            sqlite3_bind_int64(statement, 1, timestamp)
            SQLiteStatement.bind(batteryID, to: statement, index: 2)
            SQLiteStatement.bind(batteryStateID, to: statement, index: 3)
            SQLiteStatement.bind(adapterID, to: statement, index: 4)
            SQLiteStatement.bind(appID, to: statement, index: 5)
            sqlite3_bind_int(statement, 6, HistoryValueCoding.powerSourceCode(snapshot.powerSource))
            sqlite3_bind_int(statement, 7, HistoryValueCoding.thermalStateCode(snapshot.thermalState))
            sqlite3_bind_int(statement, 8, snapshot.isCharging ? 1 : 0)
            sqlite3_bind_int(statement, 9, snapshot.isCharged ? 1 : 0)
            sqlite3_bind_int(statement, 10, snapshot.externalConnected ? 1 : 0)
            sqlite3_bind_int(statement, 11, snapshot.lowPowerModeEnabled ? 1 : 0)
            SQLiteStatement.bind(HistoryValueCoding.tenthsPercent(from: snapshot.batteryLevel), to: statement, index: 12)
            SQLiteStatement.bind(snapshot.timeToEmptyMinutes, to: statement, index: 13)
            SQLiteStatement.bind(snapshot.timeToFullMinutes, to: statement, index: 14)
            SQLiteStatement.bind(HistoryValueCoding.celsiusHundredths(from: snapshot.batteryTemperatureC), to: statement, index: 15)
            SQLiteStatement.bind(HistoryValueCoding.millivolts(from: snapshot.batteryVoltageV), to: statement, index: 16)
            SQLiteStatement.bind(HistoryValueCoding.milliamps(from: snapshot.batteryCurrentA), to: statement, index: 17)
            SQLiteStatement.bind(HistoryValueCoding.milliwatts(from: snapshot.batteryPowerW), to: statement, index: 18)
            SQLiteStatement.bind(HistoryValueCoding.milliwatts(from: snapshot.adapterInputPowerW), to: statement, index: 19)
            SQLiteStatement.bind(HistoryValueCoding.millivolts(from: snapshot.adapterVoltageV), to: statement, index: 20)
            SQLiteStatement.bind(HistoryValueCoding.milliamps(from: snapshot.adapterCurrentA), to: statement, index: 21)
            SQLiteStatement.bind(HistoryValueCoding.milliwatts(from: snapshot.systemLoadW), to: statement, index: 22)
            SQLiteStatement.bind(
                HistoryValueCoding.batteryPowerSourceCode(
                    snapshot.batteryPowerSource
                ),
                to: statement,
                index: 23
            )
        }
    }

    private func snapshot(from statement: OpaquePointer?) -> TelemetrySnapshot? {
        guard let statement,
              let powerSource = HistoryValueCoding.powerSourceKind(from: sqlite3_column_int(statement, 1))
        else {
            return nil
        }

        return TelemetrySnapshot(
            timestamp: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
            batteryLevel: HistoryValueCoding.percent(fromTenths: SQLiteStatement.optionalIntValue(statement, index: 7)),
            powerSource: powerSource,
            isCharging: sqlite3_column_int(statement, 3) == 1,
            isCharged: sqlite3_column_int(statement, 4) == 1,
            externalConnected: sqlite3_column_int(statement, 5) == 1,
            timeToEmptyMinutes: SQLiteStatement.optionalIntValue(statement, index: 8),
            timeToFullMinutes: SQLiteStatement.optionalIntValue(statement, index: 9),
            designCapacityMah: SQLiteStatement.optionalIntValue(statement, index: 19),
            fullChargeCapacityMah: SQLiteStatement.optionalIntValue(statement, index: 21),
            nominalCapacityMah: SQLiteStatement.optionalIntValue(statement, index: 22),
            cycleCount: SQLiteStatement.optionalIntValue(statement, index: 23),
            designCycleCount: SQLiteStatement.optionalIntValue(statement, index: 20),
            batteryHealthText: SQLiteStatement.textValue(statement, index: 24),
            batteryHealthCondition: SQLiteStatement.textValue(statement, index: 25),
            batteryTemperatureC: HistoryValueCoding.celsius(fromHundredths: SQLiteStatement.optionalIntValue(statement, index: 10)),
            batteryVoltageV: HistoryValueCoding.volts(fromMillivolts: SQLiteStatement.optionalIntValue(statement, index: 11)),
            batteryCurrentA: HistoryValueCoding.amps(fromMilliamps: SQLiteStatement.optionalIntValue(statement, index: 12)),
            batteryPowerW: HistoryValueCoding.watts(fromMilliwatts: SQLiteStatement.optionalIntValue(statement, index: 13)),
            batteryPowerSource: HistoryValueCoding.batteryPowerSource(
                from: SQLiteStatement.optionalIntValue(
                    statement,
                    index: 30
                )
            ),
            adapterDescription: SQLiteStatement.textValue(statement, index: 26),
            adapterMaxPowerW: HistoryValueCoding.watts(fromMilliwatts: SQLiteStatement.optionalIntValue(statement, index: 27)),
            adapterInputPowerW: HistoryValueCoding.watts(fromMilliwatts: SQLiteStatement.optionalIntValue(statement, index: 14)),
            adapterVoltageV: HistoryValueCoding.volts(fromMillivolts: SQLiteStatement.optionalIntValue(statement, index: 15)),
            adapterCurrentA: HistoryValueCoding.amps(fromMilliamps: SQLiteStatement.optionalIntValue(statement, index: 16)),
            systemLoadW: HistoryValueCoding.watts(fromMilliwatts: SQLiteStatement.optionalIntValue(statement, index: 17)),
            lowPowerModeEnabled: sqlite3_column_int(statement, 6) == 1,
            thermalState: HistoryValueCoding.thermalStateName(from: sqlite3_column_int(statement, 2)),
            serialNumber: SQLiteStatement.textValue(statement, index: 18),
            frontmostAppBundleID: SQLiteStatement.textValue(statement, index: 28),
            frontmostAppName: SQLiteStatement.textValue(statement, index: 29)
        )
    }

}
