import Foundation

enum HistorySchema {
    static let statements = [
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
    ]
}
