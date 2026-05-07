#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/powerlens_packaging.sh"

APP_NAME="$POWERLENS_APP_NAME"
RELEASE_DIR="$ROOT_DIR/release"
STAGE_DIR="$RELEASE_DIR/stage"
DMG_STAGE_DIR="$RELEASE_DIR/dmg-stage"
APP_BUNDLE="$STAGE_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
SOURCE_INFO_PLIST="$POWERLENS_SOURCE_INFO_PLIST"
ENTITLEMENTS="$POWERLENS_ENTITLEMENTS"
SPARKLE_GENERATE_APPCAST_TOOL="$POWERLENS_SPARKLE_GENERATE_APPCAST_TOOL"

DEFAULT_VERSION="0.9.1"
DEFAULT_BUILD="$(powerlens_default_build_number)"
VERSION="${POWERLENS_VERSION:-$DEFAULT_VERSION}"
BUILD_NUMBER="${POWERLENS_BUILD:-$DEFAULT_BUILD}"
RELEASE_BASENAME="$APP_NAME-$VERSION"
APP_ZIP="$RELEASE_DIR/$RELEASE_BASENAME.app.zip"
DMG_PATH="$RELEASE_DIR/$RELEASE_BASENAME.dmg"
CHECKSUMS_PATH="$RELEASE_DIR/$RELEASE_BASENAME-checksums.txt"
SIGN_IDENTITY="${POWERLENS_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${POWERLENS_NOTARY_PROFILE:-}"
NOTARY_KEYCHAIN="${POWERLENS_NOTARY_KEYCHAIN:-}"
SKIP_NOTARIZATION="${POWERLENS_SKIP_NOTARIZATION:-0}"
CLEAN_BUILD="${POWERLENS_CLEAN_BUILD:-1}"
SPARKLE_FEED_URL="${POWERLENS_SPARKLE_FEED_URL:-https://progresshans.github.io/powerlens/appcast.xml}"
SPARKLE_ALPHA_FEED_URL="${POWERLENS_SPARKLE_ALPHA_FEED_URL:-https://progresshans.github.io/powerlens/appcast-alpha.xml}"
SPARKLE_PUBLIC_ED_KEY="${POWERLENS_SPARKLE_PUBLIC_ED_KEY:-}"
SPARKLE_GENERATE_APPCAST="${POWERLENS_SPARKLE_GENERATE_APPCAST:-0}"
SPARKLE_APPCAST_DIR="${POWERLENS_SPARKLE_APPCAST_DIR:-}"
SPARKLE_APPCAST_OUTPUT_PATH="${POWERLENS_SPARKLE_APPCAST_OUTPUT_PATH:-}"
SPARKLE_DOWNLOAD_URL_PREFIX="${POWERLENS_SPARKLE_DOWNLOAD_URL_PREFIX:-}"
SPARKLE_RELEASE_NOTES_URL_PREFIX="${POWERLENS_SPARKLE_RELEASE_NOTES_URL_PREFIX:-}"
SPARKLE_KEY_ACCOUNT="${POWERLENS_SPARKLE_KEY_ACCOUNT:-powerlens}"
SPARKLE_PRIVATE_ED_KEY="${POWERLENS_SPARKLE_PRIVATE_ED_KEY:-}"
SPARKLE_ED_KEY_FILE="${POWERLENS_SPARKLE_ED_KEY_FILE:-}"

validate_sparkle_public_key() {
  if [[ -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
    return
  fi

  python3 - "$SPARKLE_PUBLIC_ED_KEY" <<'PY'
import base64
import sys

key = sys.argv[1].strip()

try:
    decoded = base64.b64decode(key, validate=True)
except Exception as error:
    raise SystemExit(f"sparkle: SUPublicEDKey is not valid base64: {error}")

if len(decoded) != 32:
    raise SystemExit(f"sparkle: SUPublicEDKey must decode to 32 bytes, got {len(decoded)} bytes")
PY
}

validate_generated_appcast_signature() {
  local appcast="$1"

  if [[ -z "$SPARKLE_PRIVATE_ED_KEY" && -z "$SPARKLE_ED_KEY_FILE" ]]; then
    if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
      echo "sparkle: appcast signing key is required when SUPublicEDKey is embedded in the app" >&2
      exit 2
    fi

    echo "sparkle: appcast signing key omitted; generated appcast will not support secure updates" >&2
    return
  fi

  if ! grep -q 'sparkle:edSignature=' "$appcast"; then
    echo "sparkle: generated appcast is missing sparkle:edSignature; check the Sparkle private EdDSA key" >&2
    exit 2
  fi
}

prepare_release_dir() {
  rm -rf "$STAGE_DIR" "$DMG_STAGE_DIR" "$APP_ZIP" "$DMG_PATH" "$CHECKSUMS_PATH"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS" "$DMG_STAGE_DIR"
}

build_app_bundle() {
  cd "$ROOT_DIR"

  validate_sparkle_public_key

  if [[ "$CLEAN_BUILD" == "1" ]]; then
    swift package clean
  fi

  swift build -c release

  local build_dir
  local build_binary
  build_dir="$(swift build -c release --show-bin-path)"
  build_binary="$build_dir/$APP_NAME"

  cp "$build_binary" "$APP_BINARY"
  chmod +x "$APP_BINARY"
  powerlens_copy_sparkle_framework "$APP_FRAMEWORKS" "$APP_BINARY"
  powerlens_copy_resource_bundle "$build_dir" "$APP_RESOURCES"

  cp "$SOURCE_INFO_PLIST" "$INFO_PLIST"
  powerlens_apply_common_info_plist "$INFO_PLIST" "$VERSION" "$BUILD_NUMBER" "$SPARKLE_FEED_URL" "$SPARKLE_ALPHA_FEED_URL" "$SPARKLE_PUBLIC_ED_KEY" "1"
  if [[ -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
    echo "sparkle: SUPublicEDKey omitted; in-app updates are disabled for this build"
  fi

  powerlens_copy_app_icon "$INFO_PLIST" "$APP_RESOURCES"

  powerlens_strip_extended_attributes "$APP_BUNDLE"
}

sign_app_if_configured() {
  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "codesign: signing app with ad-hoc identity (set POWERLENS_SIGN_IDENTITY for distribution)"
    codesign --force --deep --sign - "$APP_BUNDLE"
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
    return
  fi

  echo "codesign: signing $APP_BUNDLE"

  if [[ -d "$APP_FRAMEWORKS/Sparkle.framework" ]]; then
    codesign \
      --force \
      --options runtime \
      --timestamp \
      --sign "$SIGN_IDENTITY" \
      "$APP_FRAMEWORKS/Sparkle.framework"
  fi

  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP_BUNDLE"

  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
}

generate_appcast_if_configured() {
  if [[ "$SPARKLE_GENERATE_APPCAST" != "1" ]]; then
    return
  fi

  if [[ -z "$SPARKLE_APPCAST_DIR" ]]; then
    echo "sparkle: POWERLENS_SPARKLE_APPCAST_DIR is required when POWERLENS_SPARKLE_GENERATE_APPCAST=1" >&2
    exit 2
  fi

  powerlens_require_file "$SPARKLE_GENERATE_APPCAST_TOOL"
  mkdir -p "$SPARKLE_APPCAST_DIR"
  cp "$APP_ZIP" "$SPARKLE_APPCAST_DIR/"

  local args=("$SPARKLE_GENERATE_APPCAST_TOOL" --account "$SPARKLE_KEY_ACCOUNT")
  if [[ -n "$SPARKLE_PRIVATE_ED_KEY" ]]; then
    args+=(--ed-key-file -)
  elif [[ -n "$SPARKLE_ED_KEY_FILE" ]]; then
    powerlens_require_file "$SPARKLE_ED_KEY_FILE"
    args+=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
  fi
  if [[ -n "$SPARKLE_DOWNLOAD_URL_PREFIX" ]]; then
    args+=(--download-url-prefix "$SPARKLE_DOWNLOAD_URL_PREFIX")
  fi
  if [[ -n "$SPARKLE_RELEASE_NOTES_URL_PREFIX" ]]; then
    args+=(--release-notes-url-prefix "$SPARKLE_RELEASE_NOTES_URL_PREFIX")
  fi

  args+=("$SPARKLE_APPCAST_DIR")
  echo "sparkle: generating appcast in $SPARKLE_APPCAST_DIR"
  if [[ -n "$SPARKLE_PRIVATE_ED_KEY" ]]; then
    printf '%s' "$SPARKLE_PRIVATE_ED_KEY" | "${args[@]}"
  else
    "${args[@]}"
  fi

  local generated_appcast="$SPARKLE_APPCAST_DIR/appcast.xml"
  powerlens_require_file "$generated_appcast"
  validate_generated_appcast_signature "$generated_appcast"

  if [[ -n "$SPARKLE_APPCAST_OUTPUT_PATH" ]]; then
    mkdir -p "$(dirname "$SPARKLE_APPCAST_OUTPUT_PATH")"
    cp "$generated_appcast" "$SPARKLE_APPCAST_OUTPUT_PATH"
    echo "sparkle: copied appcast to $SPARKLE_APPCAST_OUTPUT_PATH"
  fi
}

zip_app_for_notarization() {
  ditto --noqtn --noextattr -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"
}

submit_for_notarization() {
  local artifact="$1"
  local args=(submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait)

  if [[ -n "$NOTARY_KEYCHAIN" ]]; then
    args+=(--keychain "$NOTARY_KEYCHAIN")
  fi

  xcrun notarytool "${args[@]}"
}

notarize_app_if_configured() {
  if [[ -z "$SIGN_IDENTITY" || -z "$NOTARY_PROFILE" || "$SKIP_NOTARIZATION" == "1" ]]; then
    echo "notarization: skipped (set POWERLENS_SIGN_IDENTITY and POWERLENS_NOTARY_PROFILE to enable)"
    return
  fi

  echo "notarization: submitting app zip"
  submit_for_notarization "$APP_ZIP"
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
}

create_dmg() {
  ditto --noqtn --noextattr "$APP_BUNDLE" "$DMG_STAGE_DIR/$APP_NAME.app"
  ln -s /Applications "$DMG_STAGE_DIR/Applications"
  powerlens_strip_extended_attributes "$DMG_STAGE_DIR"

  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null
  powerlens_strip_extended_attributes "$DMG_PATH"
}

sign_dmg_if_configured() {
  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "codesign: skipped for dmg"
    return
  fi

  echo "codesign: signing $DMG_PATH"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
}

notarize_dmg_if_configured() {
  if [[ -z "$SIGN_IDENTITY" || -z "$NOTARY_PROFILE" || "$SKIP_NOTARIZATION" == "1" ]]; then
    echo "notarization: skipped for dmg"
    return
  fi

  echo "notarization: submitting dmg"
  submit_for_notarization "$DMG_PATH"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
}

write_checksums() {
  (
    cd "$RELEASE_DIR"
    shasum -a 256 "$(basename "$APP_ZIP")" "$(basename "$DMG_PATH")"
  ) > "$CHECKSUMS_PATH"
}

print_summary() {
  echo
  echo "Release artifacts:"
  echo "- $APP_BUNDLE"
  echo "- $APP_ZIP"
  echo "- $DMG_PATH"
  echo "- $CHECKSUMS_PATH"
}

powerlens_require_file "$SOURCE_INFO_PLIST"
powerlens_require_file "$ENTITLEMENTS"
prepare_release_dir
build_app_bundle
sign_app_if_configured
zip_app_for_notarization
notarize_app_if_configured
zip_app_for_notarization
create_dmg
sign_dmg_if_configured
notarize_dmg_if_configured
generate_appcast_if_configured
write_checksums
print_summary
