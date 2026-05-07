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
- thermal state
- the frontmost app name and bundle identifier for the high energy usage badge

## Data Stored Locally

PowerLens stores preferences in macOS `UserDefaults`, including language,
telemetry engine, menu bar display style, and Dock visibility.

PowerLens stores recent telemetry history in:

```text
~/Library/Application Support/PowerLens/history.sqlite3
```

The history database may include battery identifiers, adapter information,
telemetry samples, and the frontmost high energy usage app name/bundle
identifier. This data stays on the Mac unless you manually share, back up, or
sync that directory.

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
