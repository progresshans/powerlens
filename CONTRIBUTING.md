# Contributing to PowerLens

Thanks for helping improve PowerLens.

## Before You Start

PowerLens currently builds for Apple silicon and targets macOS 26 or later.
Development requires an Apple silicon Mac, Swift 6.2, and the Xcode command-line
tools or Xcode.

For a bug, include the PowerLens version, macOS version, Mac model, power source,
and whether the Compatible or Live Precision telemetry engine was active. Do
not post battery serial numbers, signing credentials, Sparkle keys, or other
private machine data.

For a substantial behavior change, new network request, or new use of a private
macOS interface, open an issue before investing in an implementation so the
scope and compatibility expectations can be confirmed.

## Branch and Release Flow

PowerLens uses `feature -> develop -> main -> tag` as its normal promotion path.

- Open ordinary feature, bug-fix, documentation, and dependency pull requests
  against `develop`.
- Merging a reviewed pull request into `develop` automatically builds, signs,
  notarizes, and publishes a numbered alpha release for integration testing.
  If multiple merges arrive while one automatic alpha is running, pending runs
  are intentionally coalesced to the newest `develop` commit.
- Stable, explicit-tag, and manually dispatched releases wait for a maintainer
  to approve the `release-approval` environment. Automatic `develop` alphas
  skip that approval gate.
- Treat `main` as the stable branch. Do not send ordinary feature work directly
  to `main`.
- A maintainer promotes `develop` to `main` through a reviewed pull request.
- A maintainer creates release tags from the reviewed `main` commit after the
  release checklist is complete.

Repository automation and policy files that GitHub reads from the default
branch, including `.github/dependabot.yml` and issue and pull request templates,
become active after they are promoted to `main`.

## Build and Test

From the repository root:

```bash
swift build --build-system native --arch arm64
./script/test_swiftpm.sh
./script/build_and_run.sh
```

Distribution and the default local test helper currently use SwiftPM's native
build system. With Swift 6.3 or later, run the same SwiftBuild compatibility
path used by CI with:

```bash
POWERLENS_BUILD_SYSTEM=swiftbuild ./script/test_swiftpm.sh
```

The helper builds tests with SwiftBuild, stages the generated Sparkle framework
in the runtime location expected by the test bundle, and then executes the
SwiftBuild-produced tests. It does not rebuild them with the native backend.

Before opening a pull request, also run:

```bash
bash -n script/*.sh script/lib/*.sh
plutil -lint \
  Packaging/Info.plist \
  Sources/PowerLens/Resources/en.lproj/Localizable.strings \
  Sources/PowerLens/Resources/ko.lproj/Localizable.strings
git diff --check
```

The packaged app also exposes a headless, read-only compatibility probe:

```bash
release/stage/PowerLens.app/Contents/MacOS/PowerLens \
  --system-api-probe \
  --format json \
  > release/system-api-probe.json

python3 script/verify_system_api_probe.py \
  --profile script/system-api-contracts/macos-26.json \
  --mode physical \
  release/system-api-probe.json
```

The probe reports system-interface shape and service availability, not raw
battery/adapter values or identifiers. `physical` mode requires the battery
providers expected on a supported Mac and rejects transient PowerUI queries.
CI uses `hosted` mode: it verifies packaging, the report schema, and static ABI
while reporting unavailable VM hardware as warnings rather than claiming it
was exercised. CI keeps the existing native macOS 26 release check, adds an
explicit SwiftBuild check on macOS 26, and runs the same SwiftBuild path on the
`xcode-27` preview image, which now runs macOS 27. Each matrix entry selects its
explicit OS contract (`macos-26.json` or `macos-27.json`); an unexpected host OS
still fails verification. The macOS 27 profile preserves the existing static
ABI and hardware checks, with the app's minimum deployment version kept at
26.0. Its hosted probe establishes VM compatibility, not physical macOS 27
battery or charging-policy coverage.

If physical compatibility checks are automated later, do not attach a
self-hosted Mac to the public `pull_request` trigger. Run untrusted code only on
GitHub-hosted workers; restrict a dedicated physical runner to protected
branches, tags, or an authorized `workflow_dispatch`, with a separate local
account and no personal data or release credentials.

## Change Guidelines

- Preserve raw sensor readings and their provenance. Do not force independently
  sampled values to balance.
- Separate immediate physical flow from time-stabilized status and diagnostics.
- Treat PowerUI and SMC as optional interfaces: validate runtime shape, contain
  failures, and keep a compatible fallback.
- Add focused regression tests for state transitions, missing sensors, history
  migrations, and localized user-facing copy.
- Keep telemetry local. Discuss any new network request or newly stored
  identifier explicitly in the pull request and update `PRIVACY.md`.
- Never commit certificates, notarization credentials, `.env` files, Sparkle
  private keys, exported user history, or battery identifiers.

## History Schema Upgrades and Recovery

Schema v5 adds a versioned `measurement_payload` to new samples. It preserves
the original timestamp, numeric measurements, and measurement-set provenance
used by live power calculations. Existing scaled integer columns remain the
SQL aggregation contract. Legacy rows retain their original precision and
unknown provenance; migration must not infer missing sensor sources. Chart
identity comes from `sample_id`, not the timestamp. An unreadable payload is a
read failure, not an empty result or a fallback to differently rounded values.

Before upgrading an existing schema, SQLite's backup API creates a copy beside
the database named after the schema it holds, such as
`history.sqlite3.schema-v4.sqlite3` before the v4 to v5 upgrade, including
committed WAL pages. Each upgrade keeps its own copy. A standalone backup has
owner-only permissions, is never overwritten, and must be completed before the
transactional migration starts. A failed migration rolls back. Each copy is kept
for 14 days after it is created, even if its samples pass the retention window,
so a downgrade soon after an update stays possible. The daily retention pass
then deletes it, also under `Forever`, and deletes every copy at once when
long-term history is set to `Don't keep`. Its age comes from the file's creation
date; a copy with no readable date is deleted. The same pass removes temporary
files left by an interrupted backup. These copies are short-lived recovery aids,
not a separate permanent archive.

To restore an available backup, quit PowerLens first. Move the current database
and any matching `-wal` and `-shm` files together into a separate recovery
directory, then copy the backup whose schema the older app supports to
`history.sqlite3` before starting that app. Keep the moved files: the backup does not include records written
after the upgrade. Do not lower `PRAGMA user_version` to make a newer database
look compatible. After 14 days, or once `Don't keep` has removed the backup,
preserve the current database and export needed records before planning a
downgrade.

## Dependency and Security Updates

Routine Dependabot version updates target `develop` and follow the same review
and verification path as other changes.

Dependabot security updates target the default branch, `main`. They are never
auto-merged, including for urgent advisories. Before merging, a maintainer must
review the advisory and upstream release notes, inspect manifest and lockfile
changes, and run the relevant build, test, packaging, and updater checks. After
merging a security update into `main`, promptly synchronize the same fix back to
`develop` and verify that both branches contain it.

## Pull Requests

Keep each pull request focused. Explain the observed problem, the chosen
behavior, and the exact verification performed. Resolve review conversations
only after the requested change or a documented decision is present in the
latest commit.

Release signing, notarization, appcast publication, and version tags are
maintainer-only operations. Contributors do not need release credentials.

By contributing, you agree that your contribution is licensed under the
project's `AGPL-3.0-only` license.
