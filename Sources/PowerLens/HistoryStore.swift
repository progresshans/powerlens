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

    func loadRecent(since cutoffDate: Date) async -> [TelemetrySnapshot] {
        guard let db = openDatabase() else {
            return []
        }

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
            ap.display_name
        FROM telemetry_samples s
        LEFT JOIN batteries b ON b.battery_id = s.battery_id
        LEFT JOIN battery_states bs ON bs.battery_state_id = s.battery_state_id
        LEFT JOIN adapters a ON a.adapter_id = s.adapter_id
        LEFT JOIN apps ap ON ap.app_id = s.app_id
        WHERE s.ts >= ?
        ORDER BY s.ts ASC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }

        defer {
            sqlite3_finalize(statement)
        }

        sqlite3_bind_int64(statement, 1, sqlite3_int64(cutoffDate.timeIntervalSince1970.rounded()))

        var snapshots: [TelemetrySnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let snapshot = snapshot(from: statement) {
                snapshots.append(snapshot)
            }
        }

        return snapshots
    }

    func append(_ snapshot: TelemetrySnapshot) async {
        guard let db = openDatabase() else {
            return
        }

        defer {
            sqlite3_close(db)
        }

        SQLiteStatement.execute("BEGIN IMMEDIATE TRANSACTION;", using: db)

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

            SQLiteStatement.execute("COMMIT;", using: db)
        } catch {
            SQLiteStatement.execute("ROLLBACK;", using: db)
        }
    }

    private func openDatabase() -> OpaquePointer? {
        let directory = databaseURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
            if let db {
                sqlite3_close(db)
            }
            return nil
        }

        SQLiteStatement.execute("PRAGMA journal_mode=WAL;", using: db)
        SQLiteStatement.execute("PRAGMA synchronous=NORMAL;", using: db)
        SQLiteStatement.execute("PRAGMA foreign_keys=ON;", using: db)

        for statement in HistorySchema.statements {
            SQLiteStatement.execute(statement, using: db)
        }

        return db
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
            system_load_mw
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
