#!/usr/bin/env bash
set -euo pipefail

APP_NAME="PowerLens"
BUNDLE_ID="com.progresshans.powerlens"
MIN_SYSTEM_VERSION="13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGING_DIR="$ROOT_DIR/Packaging"
RELEASE_DIR="$ROOT_DIR/release"
STAGE_DIR="$RELEASE_DIR/stage"
DMG_STAGE_DIR="$RELEASE_DIR/dmg-stage"
APP_BUNDLE="$STAGE_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
SOURCE_INFO_PLIST="$PACKAGING_DIR/Info.plist"
SOURCE_ICON="$PACKAGING_DIR/AppIcon.icns"
ENTITLEMENTS="$PACKAGING_DIR/PowerLens.entitlements"

DEFAULT_VERSION="0.9.0"
DEFAULT_BUILD="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
VERSION="${POWERLENS_VERSION:-$DEFAULT_VERSION}"
BUILD_NUMBER="${POWERLENS_BUILD:-$DEFAULT_BUILD}"
RELEASE_BASENAME="$APP_NAME-$VERSION"
APP_ZIP="$RELEASE_DIR/$RELEASE_BASENAME.app.zip"
DMG_PATH="$RELEASE_DIR/$RELEASE_BASENAME.dmg"
CHECKSUMS_PATH="$RELEASE_DIR/$RELEASE_BASENAME-checksums.txt"
SIGN_IDENTITY="${POWERLENS_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${POWERLENS_NOTARY_PROFILE:-}"
SKIP_NOTARIZATION="${POWERLENS_SKIP_NOTARIZATION:-0}"
CLEAN_BUILD="${POWERLENS_CLEAN_BUILD:-1}"

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "missing required file: $path" >&2
    exit 2
  fi
}

set_plist_value() {
  local key="$1"
  local value="$2"

  if /usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$INFO_PLIST"
  else
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$INFO_PLIST"
  fi
}

strip_extended_attributes() {
  local path="$1"

  if command -v xattr >/dev/null 2>&1 && [[ -e "$path" ]]; then
    xattr -cr "$path" 2>/dev/null || true
  fi
}

prepare_release_dir() {
  rm -rf "$STAGE_DIR" "$DMG_STAGE_DIR" "$APP_ZIP" "$DMG_PATH" "$CHECKSUMS_PATH"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$DMG_STAGE_DIR"
}

build_app_bundle() {
  cd "$ROOT_DIR"

  if [[ "$CLEAN_BUILD" == "1" ]]; then
    swift package clean
  fi

  swift build -c release

  local build_dir
  local build_binary
  local resource_bundle
  build_dir="$(swift build -c release --show-bin-path)"
  build_binary="$build_dir/$APP_NAME"
  resource_bundle="$build_dir/${APP_NAME}_${APP_NAME}.bundle"

  cp "$build_binary" "$APP_BINARY"
  chmod +x "$APP_BINARY"

  if [[ -d "$resource_bundle" ]]; then
    ditto --noqtn --noextattr "$resource_bundle" "$APP_RESOURCES/$(basename "$resource_bundle")"
  fi

  cp "$SOURCE_INFO_PLIST" "$INFO_PLIST"
  set_plist_value "CFBundleExecutable" "$APP_NAME"
  set_plist_value "CFBundleIdentifier" "$BUNDLE_ID"
  set_plist_value "CFBundleName" "$APP_NAME"
  set_plist_value "CFBundleDisplayName" "$APP_NAME"
  set_plist_value "CFBundleShortVersionString" "$VERSION"
  set_plist_value "CFBundleVersion" "$BUILD_NUMBER"
  set_plist_value "LSMinimumSystemVersion" "$MIN_SYSTEM_VERSION"

  if [[ -f "$SOURCE_ICON" ]]; then
    cp "$SOURCE_ICON" "$APP_RESOURCES/AppIcon.icns"
    set_plist_value "CFBundleIconFile" "AppIcon"
  fi

  strip_extended_attributes "$APP_BUNDLE"
}

sign_app_if_configured() {
  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "codesign: skipped (set POWERLENS_SIGN_IDENTITY to sign release artifacts)"
    return
  fi

  echo "codesign: signing $APP_BUNDLE"
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

zip_app_for_notarization() {
  ditto --noqtn --noextattr -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"
}

notarize_app_if_configured() {
  if [[ -z "$SIGN_IDENTITY" || -z "$NOTARY_PROFILE" || "$SKIP_NOTARIZATION" == "1" ]]; then
    echo "notarization: skipped (set POWERLENS_SIGN_IDENTITY and POWERLENS_NOTARY_PROFILE to enable)"
    return
  fi

  echo "notarization: submitting app zip"
  xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
}

create_dmg() {
  ditto --noqtn --noextattr "$APP_BUNDLE" "$DMG_STAGE_DIR/$APP_NAME.app"
  ln -s /Applications "$DMG_STAGE_DIR/Applications"
  strip_extended_attributes "$DMG_STAGE_DIR"

  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null
  strip_extended_attributes "$DMG_PATH"
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
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
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

require_file "$SOURCE_INFO_PLIST"
require_file "$ENTITLEMENTS"
prepare_release_dir
build_app_bundle
sign_app_if_configured
zip_app_for_notarization
notarize_app_if_configured
zip_app_for_notarization
create_dmg
sign_dmg_if_configured
notarize_dmg_if_configured
write_checksums
print_summary
