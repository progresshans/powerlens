# PowerLens GitHub Pages

This directory is intended to be the GitHub Pages source for the PowerLens
repository.

When Pages is enabled for the `docs/` directory on the default branch,
`docs/appcast.xml` is served at:

```text
https://progresshans.github.io/powerlens/appcast.xml
```

That URL is the default Sparkle feed URL embedded in release builds.

## Appcast Workflow

`docs/appcast.xml` starts as a valid empty feed so update checks do not hit a
404 before the first Sparkle-visible release is published. For actual releases,
generate it from the exact signed ZIP that will be uploaded to GitHub Releases.

Use a temporary work directory for Sparkle's generated files, then copy only the
feed into `docs/appcast.xml`:

```bash
set -a
source .env
set +a

POWERLENS_VERSION=0.9.1 \
POWERLENS_BUILD=2 \
POWERLENS_SPARKLE_GENERATE_APPCAST=1 \
POWERLENS_SPARKLE_APPCAST_DIR="$PWD/release/appcast-work" \
POWERLENS_SPARKLE_APPCAST_OUTPUT_PATH="$PWD/docs/appcast.xml" \
POWERLENS_SPARKLE_DOWNLOAD_URL_PREFIX="https://github.com/progresshans/powerlens/releases/download/v0.9.1/" \
./script/package_release.sh
```

Upload the matching `release/PowerLens-0.9.1.app.zip` to the same GitHub
Release referenced by the download URL prefix. If the ZIP is rebuilt after the
appcast is generated, regenerate `docs/appcast.xml` before publishing.

## GitHub Pages Settings

In GitHub:

1. Open the repository settings.
2. Go to `Pages`.
3. Set the source to `Deploy from a branch`.
4. Select the default branch and `/docs` folder.
5. Save and wait for Pages to publish.
