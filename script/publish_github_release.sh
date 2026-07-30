#!/usr/bin/env bash
set -euo pipefail

: "${TAG:?TAG is required}"
: "${VERSION:?VERSION is required}"
: "${PRERELEASE:?PRERELEASE is required}"
: "${LATEST:?LATEST is required}"
: "${SOURCE_SHA:?SOURCE_SHA is required}"
: "${TAG_ORIGIN:?TAG_ORIGIN is required}"
: "${RELEASE_RUN_ID:?RELEASE_RUN_ID is required}"
: "${RELEASE_NOTES_PATH:?RELEASE_NOTES_PATH is required}"
: "${RELEASE_ASSET_DIR:?RELEASE_ASSET_DIR is required}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() {
  echo "release publication: $*" >&2
  exit 2
}

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-alpha\.[0-9]+)?$ ]]; then
  die "unsupported version: $VERSION"
fi
if [[ "$TAG" != "v$VERSION" ]]; then
  die "tag $TAG does not match version $VERSION"
fi
if [[ "$PRERELEASE" != "true" && "$PRERELEASE" != "false" ]]; then
  die "PRERELEASE must be true or false"
fi
if [[ "$LATEST" != "true" && "$LATEST" != "false" ]]; then
  die "LATEST must be true or false"
fi

"$ROOT_DIR/script/verify_release_tag.sh" \
  "$TAG" \
  "$SOURCE_SHA" \
  "$TAG_ORIGIN" \
  "$RELEASE_RUN_ID"

run_marker="<!-- powerlens-release-run-id: $RELEASE_RUN_ID -->"
sha_marker="<!-- powerlens-release-sha: $SOURCE_SHA -->"
grep -Fqx "$run_marker" "$RELEASE_NOTES_PATH" \
  || die "release notes are missing the run provenance marker"
grep -Fqx "$sha_marker" "$RELEASE_NOTES_PATH" \
  || die "release notes are missing the source SHA marker"

assets=(
  "$RELEASE_ASSET_DIR/PowerLens-$VERSION.dmg"
  "$RELEASE_ASSET_DIR/PowerLens-$VERSION.app.zip"
  "$RELEASE_ASSET_DIR/PowerLens-$VERSION-checksums.txt"
)
for asset in "${assets[@]}"; do
  [[ -f "$asset" ]] || die "missing release asset: $asset"
done

(
  cd "$RELEASE_ASSET_DIR"
  shasum -a 256 -c "PowerLens-$VERSION-checksums.txt"
) || die "release asset checksum verification failed"

appcast_path="$RELEASE_ASSET_DIR/appcast.xml"
[[ -f "$appcast_path" ]] || die "missing generated appcast: $appcast_path"
python3 - "$appcast_path" <<'PY' \
  || die "generated appcast is not valid XML"
import sys
import xml.etree.ElementTree as ET

ET.parse(sys.argv[1])
PY

if gh release view "$TAG" >/dev/null 2>&1; then
  existing_body="$(gh release view "$TAG" --json body --jq .body)"
  existing_is_draft="$(gh release view "$TAG" --json isDraft --jq .isDraft)"
  grep -Fqx "$run_marker" <<< "$existing_body" \
    || die "$TAG belongs to a different workflow run"
  grep -Fqx "$sha_marker" <<< "$existing_body" \
    || die "$TAG release body records a different source SHA"
  if [[ "$existing_is_draft" != "true" && "$existing_is_draft" != "false" ]]; then
    die "$TAG returned an invalid draft state: $existing_is_draft"
  fi

  edit_args=(
    "$TAG"
    --title "$VERSION"
    --notes-file "$RELEASE_NOTES_PATH"
    --verify-tag
  )

  if [[ "$PRERELEASE" == "true" ]]; then
    edit_args+=(--prerelease --latest=false)
  else
    edit_args+=(--prerelease=false --latest)
  fi

  gh release upload "$TAG" "${assets[@]}" --clobber
  if [[ "$existing_is_draft" == "true" ]]; then
    edit_args+=(--draft=false)
  fi
  gh release edit "${edit_args[@]}"
else
  create_args=(
    "$TAG"
    "${assets[@]}"
    --title "$VERSION"
    --notes-file "$RELEASE_NOTES_PATH"
    --verify-tag
  )

  if [[ "$PRERELEASE" == "true" ]]; then
    create_args+=(--prerelease)
  fi
  if [[ "$LATEST" == "true" ]]; then
    create_args+=(--latest)
  else
    create_args+=(--latest=false)
  fi

  gh release create "${create_args[@]}"
fi
