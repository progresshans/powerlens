# Privacy

PowerLens is designed as a local macOS utility. It reads battery and power
telemetry from the current Mac and presents it in the menu bar, popover, and
dashboard.

## Network Use

PowerLens does not send analytics, telemetry, crash reports, or usage events to
a server.

If you manually choose **Check for Updates** or enable automatic update checks,
PowerLens may contact the configured Sparkle appcast URL and GitHub release
asset URLs to look for a newer version. These requests are only for app updates.

Release notarization is handled by Apple during packaging, outside the running
app. The app itself does not need an account or a PowerLens cloud service.

## Data Read Locally

PowerLens may read the following local information, depending on what macOS and
the hardware expose:

- battery percentage, charging state, charged state, and time estimates
- battery capacity, cycle count, health, temperature, voltage, current, and
  power
- battery serial number or hardware battery identifier
- adapter description, negotiated input power, voltage, current, and rated power
- estimated system load and low power mode state
- the current energy mode (Automatic, Low Power, or High Power) read with
  `pmset -g`, shown in the popover and not stored
- thermal state
- the frontmost app name and bundle identifier for the high energy usage badge

## Data Stored Locally

PowerLens stores preferences in macOS `UserDefaults`, including language,
telemetry engine, menu bar display style, and Dock visibility.

PowerLens stores recent telemetry history in:

```text
~/Library/Application Support/PowerLens/history.sqlite3
```

PowerLens also stores a bounded system-interface compatibility record in:

```text
~/Library/Application Support/PowerLens/system-compatibility.json
```

This JSON file helps distinguish an unavailable hardware service from a macOS
API or ABI change. It contains the current compatibility classification for
each inspected subsystem and at most 50 state transitions. It may include a
system component or selector name, expected and observed Objective-C type
encodings, and a normalized error domain/code. It does not contain raw battery
or adapter readings, battery identifiers, app names, user filesystem paths, or
free-form system error descriptions. Repeated observations with the same
compatibility classification are deduplicated even when bounded diagnostic
details change, and their stored observation time is refreshed at most hourly.

The history database may include battery identifiers, adapter information,
telemetry samples, and the frontmost high energy usage app name/bundle
identifier. This data stays on the Mac unless you manually share, back up, or
sync that directory.

New telemetry samples also preserve the original timestamp, numeric measurement
precision, and measurement-set source so saved power charts use the same inputs
as the live display. This payload does not add app or hardware identifiers or
store charging-policy or energy-mode metadata.

Before upgrading an older history schema, PowerLens creates a local recovery
copy in the same folder, named after the schema it holds, such as
`history.sqlite3.schema-v4.sqlite3`. Each copy contains the pre-upgrade
database, including its existing identifiers, and is readable only by the file
owner. It lets you go back to the previous version soon after an update. A copy
is kept for 14 days, even if some of its samples are older than your retention
window, and the next daily cleanup after that deletes it, including with
**Forever**. With **Don't keep**, copies are deleted at the next cleanup instead
of after 14 days. They are not uploaded.

The History settings control retention:

- full-detail telemetry samples remain for the selected window
- hourly or daily long-term storage replaces expired samples with aggregate
  power data, removes unreferenced app and adapter rows, and retains
  battery-health states for the long-term health trend; the battery serial
  number or hardware battery identifier remains in the local history database
  for as long as those states are retained
- **Don't keep** deletes expired samples and rollups, then removes app, adapter,
  battery-state, and battery rows that no retained sample still references
- **Forever** keeps full-detail samples and does not run retention pruning

Confirming a retention change schedules a purge immediately. This removes the
affected records from PowerLens, but it is not an immediate secure-erase
operation: SQLite may keep freed pages until its incremental vacuum reclaims
them.

## Delete Local Data

To remove PowerLens local data:

1. Quit PowerLens.
2. Remove the app from `Applications` if you installed it there.
3. Delete the local history folder:

   ```bash
   rm -rf ~/Library/Application\ Support/PowerLens
   ```

4. Remove PowerLens preferences if desired:

   ```bash
   defaults delete com.progresshans.powerlens
   ```

The `defaults delete` command may print an error if preferences have not been
created yet.
