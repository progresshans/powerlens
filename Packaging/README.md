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
By default it builds an ad-hoc signed local release and creates:

- `PowerLens-<version>.app.zip`
- `PowerLens-<version>.dmg`
- `PowerLens-<version>-checksums.txt`

Set `POWERLENS_SIGN_IDENTITY` to a `Developer ID Application` certificate name
to sign the app and DMG. Set `POWERLENS_NOTARY_PROFILE` to a stored
`notarytool` keychain profile to notarize and staple the app and DMG.
Set `POWERLENS_SPARKLE_PUBLIC_ED_KEY` to the Sparkle EdDSA public key to enable
in-app update checks in the resulting build.
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
- signing certificates and notarization credentials are intentionally local and
  are not stored in the repository

## Sparkle Updates

PowerLens uses Sparkle for in-app update checks. The app reads its update feed
from `SUFeedURL`, which defaults to:

```text
https://progresshans.github.io/powerlens/appcast.xml
```

Generate a Sparkle EdDSA key once on a maintainer machine:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account powerlens
```

Put only the printed public key in `POWERLENS_SPARKLE_PUBLIC_ED_KEY`. The
private key stays in Keychain or another local secret store.

To generate an appcast while packaging, set the optional appcast variables from
`.env.example`, then run the release script. The script copies the signed app
ZIP into the appcast directory and invokes Sparkle's `generate_appcast` tool.

## Release Checklist

1. build a release with `POWERLENS_SIGN_IDENTITY` and
   `POWERLENS_NOTARY_PROFILE`
2. validate the resulting app bundle with `script/verify_distribution.sh`
3. install the DMG on a clean macOS user account and confirm first-launch
   Gatekeeper behavior
4. generate and publish the Sparkle appcast when the release should be visible
   to in-app update checks
5. publish the DMG, ZIP, checksum file, and release notes together
