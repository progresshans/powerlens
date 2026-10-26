# Changelog

All notable changes to PowerLens will be documented in this file.

PowerLens uses `0.x` versioning until the first stable `1.0` release.

## [Unreleased]

### Added

- The popover shows the current energy mode and opens Battery settings to
  change it. Macs with High Power Mode show Automatic, Low Power, or High
  Power; other Macs show whether Low Power Mode is on.
- The popover lists up to three apps using the most energy.
- The Dashboard charts charger and Mac power for the last hour from saved
  history.
- Settings previews each menu bar style and describes each telemetry engine.

### Changed

- Redesigned the popover, Dashboard, and Settings for macOS 26 with Liquid
  Glass controls, system colors, and system type sizes. Status text now says
  what is happening and what to do next in plain language, in English and
  Korean.
- Power flow is drawn as soft gradient strands whose width follows watts. The
  battery appears only while it is charging or supplying power. In the
  popover, a thin light travels along each strand and changed digits roll into
  place; both run in Core Animation and stop when Reduce Motion is on.
- The Dashboard now has Now, Battery, and History pages. Power flow and up to
  two current diagnostics appear on the Now page.
- In Low Power Mode, the menu bar battery icon fills yellow, matching the macOS
  battery icon. A sustained charger shortfall adds a red badge instead of
  changing the fill.
- The Dashboard and popover no longer draw while hidden, which lowers
  PowerLens's energy use when only its menu bar icon is visible.
- Adapter ratings and battery capacities use whole numbers with digit
  grouping, such as 97W and 6,249 mAh.

## [0.9.5] - 2026-10-20

### Changed

- Power flow, Dashboard summaries, and the menu bar now calculate displayed
  values from the system power reading, so input, battery, and system power add
  up and stay within the adapter rating. Tooltips show the original sensor
  readings and how each value was calculated; history and diagnostics keep the
  original measurements. This replaces the 0.9.3 approach of showing each
  sensor's reading even when they did not add up.
- Connecting or disconnecting a charger updates the menu bar immediately instead
  of waiting for the next refresh. Cached readings from the previous power
  source are marked delayed as soon as the connection changes, until a matching
  reading arrives. Waking the Mac refreshes the status without losing the current
  charging or warning state.
- High-energy app sampling pauses while no PowerLens window or popover is open,
  and startup no longer loads 30 days of history.
- Updated Sparkle to 2.10.0.

### Fixed

- Managed charging status is no longer repeated in summary diagnostics when it
  is already the primary status.
- Opening the popover or Dashboard refreshes power readings immediately, and
  outdated readings are no longer shown as live.
- Slow high-energy app scans no longer delay subsequent power readings.
- Insights includes retained raw and summarized history after retention changes,
  refreshes when new history is saved, and no longer shows results from a
  previously selected range.
- Summarized history keeps accurate averages when some sensor readings are
  missing, and no longer counts one continuous charge twice.
- Refresh, Settings, Dashboard, and Quit remain available when the first
  telemetry read fails, and saved history can still be opened.
- Changing the app language no longer sends diagnostic notifications again.
- History exports report save failures and no longer freeze the interface while
  writing files.
- Manual refreshes during startup wait until history is ready before saving.
- On Macs with a built-in battery, a connected UPS no longer replaces the
  battery's status.
- On Korean systems, the standard Edit, View, Window, and Help menus and other
  system-provided panels appear in Korean instead of English.

## [0.9.4] - 2026-08-29

### Security

- Updated Sparkle to 2.9.6 to incorporate upstream security hardening for
  update installation and validation.

## [0.9.3] - 2026-08-12

### Added

- Read-only awareness of macOS manual and adaptive charging limits, including
  distinct states for charging below a configured limit, holding at the limit,
  and observed charging above the limit.
- Explicit live, delayed, and unavailable telemetry states, plus a visible
  local-history storage status.

### Changed

- Updated Sparkle to 2.9.4.
- Power-flow views preserve independently observed adapter, battery, and system
  readings instead of forcing mismatched sensors to balance.
- Charging-limit diagnostics describe only what PowerLens can observe and no
  longer guess whether macOS is temporarily charging or targeting 100%.
- High-energy app sampling now runs outside the main actor and reuses results
  between 10-second measurements.
- Choosing not to retain older history now explains the affected data and asks
  for confirmation before permanently deleting expired samples, rollups,
  long-term health history, and unreferenced metadata.
- Raised the minimum supported operating system to macOS 26.
- The charging and external-power menu bar icons now draw their badge over the
  battery at display time instead of shipping a pre-composed icon for every
  level, which retires 42 derived assets.

### Fixed

- Internally balanced SMC or PowerTelemetry power sets now keep the live power
  route usable when a separately cached battery-current sample points in the
  opposite direction, while diagnostics continue to report the conflict.
- PowerTelemetry battery power now uses the same charge/discharge sign
  convention as SMC, and unavailable zero input voltage/current readings are
  shown as missing instead of `0.00`.
- Managed charging states remain stable through brief sensor mismatches and
  transition only after sustained contradictory evidence.
- Derived power values keep their approximation and provenance markers across
  the UI and exported history.
- Voltage-less battery-current readings are no longer used to fabricate a
  conflicting power value.
- Telemetry refresh and local-history failures no longer leave an apparently
  healthy live or storage status.
- History schema changes now use checked, versioned migrations instead of
  silently ignoring SQLite errors.
- Local packages with a Sparkle public key and a Keychain-managed private key
  no longer exit silently before the build starts.
- Stable release publishing now requires an exact, non-empty version section
  instead of falling back to `[Unreleased]`.
- The 25% menu bar battery icon drew a fill closer to 30%, leaving it nearly
  indistinguishable from the 30% icon. Every 5% step is now evenly spaced.
- The external-power menu bar icon drew a vertically short fill below 25%. The
  fill now spans the full battery height at every level.
- The charging menu bar icon showed the same fill for 60%, 65% and 70%, and the
  external-power icon for 45% through 70%, because the pre-composed assets
  discarded the fill beside the badge. Both now track the level, and the jump at
  75% is no longer abrupt. A badge still covers part of the bar, so a few
  adjacent levels above 45% remain hard to tell apart.

## [0.9.2] - 2026-07-15

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
