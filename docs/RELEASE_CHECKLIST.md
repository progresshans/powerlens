# PowerLens Release Checklist

Use this checklist for stable and alpha releases. Merging a reviewed pull
request into `develop` automatically builds and publishes a numbered alpha
release without deployment approval. Stable releases, explicit tag releases,
and any manually initiated alpha release remain deliberate and wait for the
`release-approval` environment.

## GitHub Environment Policy

- [ ] Confirm the `release` environment retains the signing, notarization, and
      Sparkle secrets plus its branch and tag policies, but has no required
      reviewers. This environment supplies secrets after the workflow's
      approval decision; it must not add a second approval gate.
- [ ] Confirm the `release-approval` environment has the intended maintainer
      reviewer and branch and tag policies, but no release secrets. It is the
      only deployment approval gate.

## Code and Metadata

- [ ] Update `CHANGELOG.md` with user-facing Added, Changed, and Fixed entries.
- [ ] For a stable release, confirm an exact, non-empty `[<version>]` section
      exists. Explicit alpha releases may fall back to `[Unreleased]` but also
      require non-empty notes; only automatic `develop` alphas may use the
      generic preview note.
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
- [ ] Confirm the generated appcast has the expected channel, display version,
      Sparkle build number greater than the highest build in either published
      channel, download URL, length, EdDSA signature, and `26.0` minimum system
      version.
- [ ] Verify DMG, ZIP, and checksum filenames match the release version.

## Publication

- [ ] For an automatic alpha, merge the reviewed commit into `develop` and
      confirm the latest intended commit has a scheduled workflow that skips the
      `release-approval` job. When another automatic alpha is already active,
      expect multiple pending merges to coalesce to the newest `develop` commit
      rather than publishing every intermediate commit.
- [ ] For a stable or manually initiated alpha, push an explicit `v<version>` or
      `v<version>-alpha.<n>` tag, or manually dispatch the workflow with the
      matching channel. These explicit releases must not be coalesced.
- [ ] For a stable, explicit-tag, or manually dispatched release, approve the
      `release-approval` environment only after reviewing the exact commit,
      expected version and channel, source CHANGELOG entries, and CI result.
      Automatic `develop` alphas must not request this approval.
- [ ] After metadata resolution, confirm an automatic alpha's annotated tag
      points to the exact source commit and records the current workflow run
      ID. For an explicit tag release, confirm the existing tag points to that
      commit. A manual dispatch intentionally has no tag yet.
- [ ] For a manual dispatch, confirm the publication job preserves the live
      feeds and accepts the appcast progression before it reserves the
      annotated tag. A rejected older version must leave no remote tag.
- [ ] If any stage fails after tag reservation, rerun that same workflow. Do
      not dispatch a different run for the reserved version; a different run is
      intentionally prevented from overwriting it. Do not rerun a deterministic
      appcast progression rejection: an automatic alpha keeps its unpublished
      reserved tag and a newer `develop` run must advance past it; an explicit
      release needs a deliberately newer version and tag after investigation.
- [ ] Verify the GitHub Release body contains the intended CHANGELOG section or,
      for an automatic alpha with no entries, the expected generic preview
      note.
- [ ] Download the published assets and verify their checksums.
- [ ] Confirm the stable or alpha appcast serves the new item while the other
      channel remains intact.
- [ ] Perform an installed-app update check against the published feed.
