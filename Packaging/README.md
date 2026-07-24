# Packaging Notes

This folder holds distribution metadata for `PowerLens`.

## Files

- `Info.plist`
  - canonical app bundle metadata used by local bundle staging and future release packaging
- `PowerLens.entitlements`
  - baseline entitlements file for future Developer ID signing and hardened runtime work
- `AppIcon.png`
  - 1024px master app icon artwork
- `AppIcon.icns`
  - macOS icon bundle copied into local app builds

## Release Packaging

Run `script/package_release.sh` to create release artifacts under `release/`.
PowerLens release artifacts support Apple silicon Macs (M1 or later) running
macOS 13 or later. The packaging script builds the PowerLens executable
explicitly for arm64, then rejects the bundle unless that executable contains
exactly the arm64 architecture. By default it builds an ad-hoc signed local
release and creates:

- `PowerLens-<version>.app.zip`
- `PowerLens-<version>.dmg`
- `PowerLens-<version>-checksums.txt`

Set `POWERLENS_SIGN_IDENTITY` to a `Developer ID Application` certificate name
to sign the app and DMG. Set `POWERLENS_NOTARY_PROFILE` to a stored
`notarytool` keychain profile to notarize and staple the app and DMG.
Set `POWERLENS_SPARKLE_PUBLIC_ED_KEY` to the Sparkle EdDSA public key to enable
in-app update checks in the resulting build. Set
`POWERLENS_SPARKLE_ALPHA_FEED_URL` when the alpha update feed should differ
from the default GitHub Pages URL.
For local use, copy `.env.example` to `.env`, update the identity, then run:

```bash
set -a
source .env
set +a
./script/package_release.sh
```

## Current State

- local builds are staged into `dist/PowerLens.app`
- app icon packaging is configured
- release packaging creates ZIP and DMG artifacts
- release packaging supports Developer ID signing, notarization, stapling, and
  checksum generation when local environment variables are provided
- release packaging embeds Sparkle and can optionally generate an appcast when
  local Sparkle signing material is available
- PowerLens's main executable is arm64-only; the embedded Sparkle framework may
  remain universal because only the app executable defines PowerLens's supported
  architecture
- signing certificates and notarization credentials are intentionally local and
  are not stored in the repository

## Sparkle Updates

PowerLens uses Sparkle for in-app update checks. The app reads the stable
update feed from `SUFeedURL`, which defaults to:

```text
https://progresshans.github.io/powerlens/appcast.xml
```

The optional alpha update channel reads from `SUAlphaFeedURL`, which defaults
to:

```text
https://progresshans.github.io/powerlens/appcast-alpha.xml
```

Generate a Sparkle EdDSA key once on a maintainer machine:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account powerlens
```

Put only the printed public key in `POWERLENS_SPARKLE_PUBLIC_ED_KEY`, including
any trailing `=` padding. The key must be valid base64 that decodes to 32 bytes.
Leading or trailing whitespace is trimmed by the packaging script, but the key
should still be stored as a single line. The private key stays in Keychain or
another local secret store.

To generate an appcast while packaging, set the optional appcast variables from
`.env.example`, then run the release script. When `SUPublicEDKey` is embedded in
the app, the script fails if the generated appcast does not contain
`sparkle:edSignature` for the current archive. Local maintainers can let
Sparkle sign through Keychain with `--account powerlens`; CI passes an exported
private EdDSA key through `POWERLENS_SPARKLE_PRIVATE_ED_KEY`. The script copies
the signed app ZIP into a temporary appcast directory and invokes Sparkle's
`generate_appcast` tool. Set
`POWERLENS_SPARKLE_APPCAST_OUTPUT_PATH="$PWD/docs/appcast.xml"` for stable
releases or `POWERLENS_SPARKLE_APPCAST_OUTPUT_PATH="$PWD/docs/appcast-alpha.xml"`
for alpha releases to copy the generated feed into the local `docs/` directory
without committing the ZIP archive.

The repository is prepared for GitHub Pages deployed by GitHub Actions. The
production appcast URL is:

```text
https://progresshans.github.io/powerlens/appcast.xml
```

The alpha channel URL is:

```text
https://progresshans.github.io/powerlens/appcast-alpha.xml
```

For a local end-to-end update smoke test, run:

```bash
./script/test_sparkle_update.sh
```

The test script builds a synthetic older app, builds a newer update archive,
generates a local appcast, serves it from `127.0.0.1`, and opens the older app.
It is meant to verify the Sparkle UI and update path before publishing a real
GitHub Release.

## GitHub Actions

PowerLens has two workflow layers:

- `.github/workflows/ci.yml`
  - runs on pull requests and pushes to `main` and `develop`
  - runs on an Apple silicon runner and executes `swift test --arch arm64`
  - validates scripts, metadata, and appcast XML
  - performs an ad-hoc package smoke build without notarization and verifies
    that the PowerLens executable is exactly arm64
- `.github/workflows/release.yml`
  - runs on `v*` tags, `develop` pushes, or manual dispatch
  - runs on an Apple silicon runner
  - builds an arm64 executable, then signs, notarizes, and packages the app
  - verifies that the packaged PowerLens executable is exactly arm64
  - creates or updates a GitHub Release
  - regenerates the stable or alpha Sparkle appcast
  - deploys the appcast site through GitHub Pages Actions

Stable releases should normally be published by pushing a version tag such as
`v0.9.1`, or by manually dispatching the release workflow. Develop branch pushes
publish alpha prereleases with the GitHub Actions run number, for example
`0.9.2-alpha.123`. By default, the alpha base version is inferred from the
latest stable tag by bumping the patch version. Set the optional repository
variable `POWERLENS_ALPHA_BASE_VERSION` only when the next alpha line should
target a minor or major version such as `0.10.0` or `1.0.0`.

Set the repository's GitHub Pages source to `GitHub Actions`. The release
workflow publishes the `docs/` site as a Pages artifact after preserving the
currently published feed for the other update channel.

The release workflow requires these GitHub Secrets:

- `POWERLENS_SIGN_IDENTITY`
  - exact codesigning identity, for example
    `Developer ID Application: HYEONJIN HAN (262HQB69RN)`
- `POWERLENS_DEVELOPER_ID_APPLICATION_P12_BASE64`
  - base64-encoded exported Developer ID Application `.p12`
- `POWERLENS_DEVELOPER_ID_APPLICATION_P12_PASSWORD`
  - password for the exported `.p12`
- `POWERLENS_KEYCHAIN_PASSWORD`
  - temporary CI keychain password
- `POWERLENS_NOTARY_APPLE_ID`
  - Apple ID used for notarization
- `POWERLENS_NOTARY_TEAM_ID`
  - Apple Developer Team ID
- `POWERLENS_NOTARY_PASSWORD`
  - Apple app-specific password for notarization
- `POWERLENS_SPARKLE_PUBLIC_ED_KEY`
  - Sparkle public EdDSA key embedded in the app; keep the trailing `=` padding
    from `generate_keys`
- `POWERLENS_SPARKLE_PRIVATE_ED_KEY`
  - exported Sparkle private EdDSA key used only to sign appcasts

The private Sparkle key can be exported on a maintainer Mac with:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account powerlens -x ./sparkle-private-ed-key.txt
```

Store the file contents in the `POWERLENS_SPARKLE_PRIVATE_ED_KEY` secret, then
delete the exported local file. The exported key should be a single-line base64
value. Current Sparkle keys decode to 32 bytes; older Sparkle exports can decode
to 96 bytes and are still accepted by the release tooling.

## Release Checklist

1. build a release with `POWERLENS_SIGN_IDENTITY` and
   `POWERLENS_NOTARY_PROFILE`
2. validate the resulting app bundle with `script/verify_distribution.sh`
   and confirm the PowerLens executable reports exactly `arm64` (a universal
   nested Sparkle framework is expected and allowed)
3. install the DMG on a clean macOS user account and confirm first-launch
   Gatekeeper behavior
4. generate and publish the Sparkle appcast when the release should be visible
   to in-app update checks
5. publish the DMG, ZIP, checksum file, and release notes together
