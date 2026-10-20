import Foundation

enum HistorySchema {
    static let currentVersion = 4

    static let creationStatements = [
        """
        CREATE TABLE IF NOT EXISTS batteries (
            battery_id INTEGER PRIMARY KEY,
            battery_key TEXT NOT NULL UNIQUE,
            serial_number TEXT,
            design_capacity_mah INTEGER,
            design_cycle_count INTEGER,
            first_seen_ts INTEGER NOT NULL,
            last_seen_ts INTEGER NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS battery_states (
            battery_state_id INTEGER PRIMARY KEY,
            battery_id INTEGER NOT NULL,
            state_key TEXT NOT NULL UNIQUE,
            full_charge_capacity_mah INTEGER,
            nominal_capacity_mah INTEGER,
            cycle_count INTEGER,
            battery_health_text TEXT,
            battery_health_condition TEXT,
            first_seen_ts INTEGER NOT NULL,
            last_seen_ts INTEGER NOT NULL,
            FOREIGN KEY (battery_id) REFERENCES batteries(battery_id)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS adapters (
            adapter_id INTEGER PRIMARY KEY,
            adapter_key TEXT NOT NULL UNIQUE,
            description TEXT,
            max_power_mw INTEGER,
            first_seen_ts INTEGER NOT NULL,
            last_seen_ts INTEGER NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS apps (
            app_id INTEGER PRIMARY KEY,
            app_key TEXT NOT NULL UNIQUE,
            bundle_identifier TEXT,
            display_name TEXT NOT NULL,
            first_seen_ts INTEGER NOT NULL,
            last_seen_ts INTEGER NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS telemetry_samples (
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
            system_load_mw INTEGER,
            battery_power_source_code INTEGER,
            FOREIGN KEY (battery_id) REFERENCES batteries(battery_id),
            FOREIGN KEY (battery_state_id) REFERENCES battery_states(battery_state_id),
            FOREIGN KEY (adapter_id) REFERENCES adapters(adapter_id),
            FOREIGN KEY (app_id) REFERENCES apps(app_id)
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS telemetry_samples_ts_idx
        ON telemetry_samples(ts);
        """,
        """
        CREATE INDEX IF NOT EXISTS telemetry_samples_battery_state_idx
        ON telemetry_samples(battery_state_id);
        """,
        """
        CREATE INDEX IF NOT EXISTS telemetry_samples_adapter_idx
        ON telemetry_samples(adapter_id);
        """,
        """
        CREATE INDEX IF NOT EXISTS telemetry_samples_app_idx
        ON telemetry_samples(app_id);
        """,
        """
        CREATE TABLE IF NOT EXISTS history_rollups (
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
            system_load_sum_mw INTEGER,
            system_load_count INTEGER,
            adapter_input_power_sum_mw INTEGER,
            adapter_input_power_count INTEGER,
            battery_temperature_sum_c_x100 INTEGER,
            battery_temperature_count INTEGER,
            first_sample_ts INTEGER,
            first_is_charging INTEGER,
            last_is_charging INTEGER,
            PRIMARY KEY (bucket_start, bucket_seconds)
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS history_rollups_bucket_idx
        ON history_rollups(bucket_start);
        """,
    ]

    /// Older prerelease databases did not set `user_version`, so migrations
    /// are guarded by actual column presence rather than only a version number.
    static let columnMigrations = [
        ColumnMigration(
            table: "telemetry_samples",
            column: "battery_power_source_code",
            sql: """
            ALTER TABLE telemetry_samples
            ADD COLUMN battery_power_source_code INTEGER;
            """
        ),
        ColumnMigration(
            table: "history_rollups",
            column: "on_battery_seconds",
            sql: """
            ALTER TABLE history_rollups
            ADD COLUMN on_battery_seconds INTEGER;
            """
        ),
        ColumnMigration(
            table: "history_rollups",
            column: "on_external_seconds",
            sql: """
            ALTER TABLE history_rollups
            ADD COLUMN on_external_seconds INTEGER;
            """
        ),
        ColumnMigration(
            table: "history_rollups",
            column: "charge_sessions",
            sql: """
            ALTER TABLE history_rollups
            ADD COLUMN charge_sessions INTEGER;
            """
        ),
    ] + rollupStatisticsColumns.map { column in
        ColumnMigration(
            table: "history_rollups",
            column: column,
            sql: "ALTER TABLE history_rollups ADD COLUMN \(column) INTEGER;"
        )
    }

    // Version 3 discarded valid-value counts and charging boundary states.
    // Leave these fields NULL in old rows: existing estimates remain readable,
    // but migration cannot reconstruct observations whose raw rows are gone.
    private static let rollupStatisticsColumns = [
        "system_load_sum_mw",
        "system_load_count",
        "adapter_input_power_sum_mw",
        "adapter_input_power_count",
        "battery_temperature_sum_c_x100",
        "battery_temperature_count",
        "first_sample_ts",
        "first_is_charging",
        "last_is_charging",
    ]
}

struct ColumnMigration {
    let table: String
    let column: String
    let sql: String
}
