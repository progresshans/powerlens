# Changelog

All notable changes to PowerLens will be documented in this file.

PowerLens uses `0.x` versioning until the first stable `1.0` release.

## [0.9.2] - Unreleased

### Added

- Insights view with selectable time ranges (24 hours, 7 days, 30 days, all),
  summary statistics, interactive scrubbing charts, and long-term battery health
  and charge-cycle trends.
- Optional diagnostic notifications for charger and battery conditions, with a
  Settings toggle and debouncing.
- CSV and JSON export of local history for the selected range.
- Launch-at-login option.
- Configurable local-history retention: full-resolution samples are kept for a
  chosen window (30 days, 90 days, 1 year, or forever); older data is
  downsampled to an hourly or daily resolution and kept indefinitely (or
  discarded), with incremental vacuum so the database stays bounded.

### Changed

- High energy usage now ranks the apps using the most CPU and idle wakeups,
  grouping helper processes under their app, instead of showing only the
  foreground app.
- Rebuilt the Settings window with a native grouped form for consistent
  alignment, popup menus, and standard toggles.
- Introduced a shared design-token layer and unified card surface that adopts
  Liquid Glass on macOS 26 with a fallback on earlier systems.

### Fixed

- Telemetry-read failures now surface a clear in-app message instead of an
  indefinite loading spinner.
- Insights chart scrubbing no longer shifts the plot when reaching the chart
  edges.

## [0.9.1] - 2026-05-07

### Added

- Sparkle-based software update checks from the app menu and Settings.

### Changed

- Shared local and release bundle-staging logic between packaging scripts.

## [0.9.0] - 2026-05-02

### Added

- macOS menu bar app for live battery and power telemetry.
- Popover with power-flow visualization, diagnostics, battery snapshot, high
  energy usage badge, and power details.
- Dashboard sections for overview, power flow, battery, diagnostics, and
  history.
- Battery/power-flow states for adapter coverage, battery assist, charging,
  holding current, and battery-only discharge.
- Menu bar display styles for PowerLens text, power text, battery icon, and
  battery-only icon.
- Custom 5% step battery icon assets for normal, charging, and external-power
  holding states.
- Automatic, compatible, and live precision telemetry engine settings.
- English, Korean, and system-language display settings.
- Local SQLite history store for recent telemetry.
- Developer ID release packaging script with signing, notarization, DMG
  creation, and checksum output.
- AGPL-3.0-only project license.
