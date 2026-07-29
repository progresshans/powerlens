# PowerLens Release Checklist

Use this checklist for stable and alpha releases. Merging a reviewed pull
request into `develop` automatically publishes a numbered alpha release.
Stable releases and any manually initiated alpha release remain deliberate.

## Code and Metadata

- [ ] Update `CHANGELOG.md` with user-facing Added, Changed, and Fixed entries.
- [ ] For a stable release, confirm an exact, non-empty `[<version>]` section
      exists; `[Unreleased]` is an alpha-only fallback.
- [ ] Confirm `Package.resolved` contains the intended Sparkle version and
      revision.
- [ ] Run `swift test --arch arm64`.
- [ ] Validate shell scripts, property lists, localized strings, and appcast XML.
- [ ] Confirm English and Korean placeholders match.
- [ ] Confirm required CI passes on the exact release commit.
- [ ] Resolve applicable pull-request review conversations.

## Runtime Compatibility

- [ ] Launch a packaged build on the current supported macOS release.
- [ ] Launch on macOS 26.0 using a physical Mac or maintained test machine.
- [ ] Verify a battery-equipped Mac can read IOKit telemetry.
- [ ] Exercise Compatible and Live Precision modes with one unavailable or
      partial sensor path and confirm fallback does not crash.
- [ ] Confirm a missing or changed PowerUI selector produces an unavailable
      charging-policy observation rather than a crash or guessed state.
- [ ] Open the menu bar popover, Dashboard, Settings, and Insights.
- [ ] Confirm a failed refresh changes the live indicator to delayed/unavailable
      and a later success recovers it.

## Distribution

- [ ] Build with the Developer ID identity and notarization profile.
- [ ] Run `./script/verify_distribution.sh release/stage/PowerLens.app`.
- [ ] Confirm the PowerLens executable is arm64 and the minimum system version
      is 26.0.
- [ ] Validate app and DMG signatures, hardened runtime, notarization tickets,
      and Gatekeeper assessment.
- [ ] Install the DMG in a clean macOS user account and verify first launch.
- [ ] Run `./script/test_sparkle_update.sh` on a maintainer Mac.
- [ ] Confirm the generated appcast has the expected channel, version,
      download URL, length, EdDSA signature, and `26.0` minimum system version.
- [ ] Verify DMG, ZIP, and checksum filenames match the release version.

## Publication

- [ ] For an automatic alpha, merge the reviewed commit into `develop` and
      confirm the workflow selected the expected base version and the next
      per-version alpha suffix.
- [ ] For a stable or manually initiated alpha, push an explicit `v<version>` or
      `v<version>-alpha.<n>` tag, or manually dispatch the workflow with the
      matching channel.
- [ ] Approve the protected `release` environment only after reviewing the
      commit, version, generated notes, and CI result.
- [ ] Verify the GitHub Release body contains the intended CHANGELOG section.
- [ ] Download the published assets and verify their checksums.
- [ ] Confirm the stable or alpha appcast serves the new item while the other
      channel remains intact.
- [ ] Perform an installed-app update check against the published feed.
