# Changelog

All notable changes to PowerLens will be documented in this file.

PowerLens uses `0.x` versioning until the first stable `1.0` release.

## [0.9.1] - Unreleased

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
