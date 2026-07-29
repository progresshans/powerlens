# Security Policy

## Supported Versions

Security fixes are applied to the latest stable PowerLens release. Alpha
releases are previews and should be updated to the newest available build.

## Report a Vulnerability

Please use GitHub's private vulnerability reporting form:

<https://github.com/progresshans/powerlens/security/advisories/new>

Do not open a public issue for a suspected vulnerability. Include:

- the affected PowerLens and macOS versions
- a minimal reproduction or proof of concept
- the expected security impact
- whether the issue involves Sparkle, release signing, local history, or a
  private macOS interface

The maintainer aims to acknowledge a report within three business days and
provide an initial assessment within seven business days. These are response
targets, not a disclosure deadline. Please coordinate public disclosure until a
fix and update path are available.

## Security Boundaries

- PowerLens stores telemetry locally and does not send product analytics.
- Sparkle update metadata and release assets are the app's primary network and
  software-supply-chain boundary.
- PowerUI and SMC access are unsupported/private macOS interfaces. PowerLens
  treats missing or changed interfaces as unavailable and must not bypass
  macOS security controls to obtain them.
- Developer ID, notarization, and Sparkle private keys belong only in protected
  maintainer or GitHub Actions secret storage.
