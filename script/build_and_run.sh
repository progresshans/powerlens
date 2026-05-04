#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="PowerLens"
BUNDLE_ID="com.progresshans.powerlens"
MIN_SYSTEM_VERSION="13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGING_DIR="$ROOT_DIR/Packaging"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
SOURCE_INFO_PLIST="$PACKAGING_DIR/Info.plist"
SOURCE_ICON="$PACKAGING_DIR/AppIcon.icns"
DEFAULT_VERSION="0.9.0"
DEFAULT_BUILD="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
VERSION="${POWERLENS_VERSION:-$DEFAULT_VERSION}"
BUILD_NUMBER="${POWERLENS_BUILD:-$DEFAULT_BUILD}"

kill_running_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

require_packaging_inputs() {
  if [[ ! -f "$SOURCE_INFO_PLIST" ]]; then
    echo "missing packaging plist: $SOURCE_INFO_PLIST" >&2
    exit 2
  fi
}

build_bundle() {
  cd "$ROOT_DIR"
  swift build

  local build_dir
  local build_binary
  build_dir="$(swift build --show-bin-path)"
  build_binary="$build_dir/$APP_NAME"
  local resource_bundle="$build_dir/${APP_NAME}_${APP_NAME}.bundle"

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"
  cp "$build_binary" "$APP_BINARY"
  chmod +x "$APP_BINARY"
  if [[ -d "$resource_bundle" ]]; then
    cp -R "$resource_bundle" "$APP_BUNDLE/"
  fi
  cp "$SOURCE_INFO_PLIST" "$INFO_PLIST"

  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MIN_SYSTEM_VERSION" "$INFO_PLIST"

  if [[ -f "$SOURCE_ICON" ]]; then
    cp "$SOURCE_ICON" "$APP_RESOURCES/AppIcon.icns"
    if /usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$INFO_PLIST" >/dev/null 2>&1; then
      /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$INFO_PLIST"
    else
      /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$INFO_PLIST"
    fi
  fi
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

require_packaging_inputs
kill_running_app
build_bundle

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
