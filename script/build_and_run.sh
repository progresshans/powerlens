#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/powerlens_packaging.sh"

APP_NAME="$POWERLENS_APP_NAME"
BUNDLE_ID="$POWERLENS_BUNDLE_ID"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
SOURCE_INFO_PLIST="$POWERLENS_SOURCE_INFO_PLIST"
DEFAULT_VERSION="0.9.2"
DEFAULT_BUILD="$(powerlens_default_build_number)"
VERSION="${POWERLENS_VERSION:-$DEFAULT_VERSION}"
BUILD_NUMBER="${POWERLENS_BUILD:-$DEFAULT_BUILD}"
SPARKLE_FEED_URL="${POWERLENS_SPARKLE_FEED_URL:-https://progresshans.github.io/powerlens/appcast.xml}"
SPARKLE_ALPHA_FEED_URL="${POWERLENS_SPARKLE_ALPHA_FEED_URL:-https://progresshans.github.io/powerlens/appcast-alpha.xml}"
SPARKLE_PUBLIC_ED_KEY="${POWERLENS_SPARKLE_PUBLIC_ED_KEY:-}"

kill_running_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

require_packaging_inputs() {
  powerlens_require_file "$SOURCE_INFO_PLIST"
}

sign_bundle_for_local_run() {
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
}

build_bundle() {
  cd "$ROOT_DIR"
  swift build --arch "$POWERLENS_BUILD_ARCH"

  local build_dir
  local build_binary
  build_dir="$(swift build --arch "$POWERLENS_BUILD_ARCH" --show-bin-path)"
  build_binary="$build_dir/$APP_NAME"

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS"
  cp "$build_binary" "$APP_BINARY"
  chmod +x "$APP_BINARY"
  powerlens_require_exact_executable_architecture "$APP_BINARY" "$POWERLENS_BUILD_ARCH"
  powerlens_copy_sparkle_framework "$APP_FRAMEWORKS" "$APP_BINARY"
  powerlens_copy_resource_bundle "$build_dir" "$APP_RESOURCES"
  cp "$SOURCE_INFO_PLIST" "$INFO_PLIST"

  powerlens_apply_common_info_plist "$INFO_PLIST" "$VERSION" "$BUILD_NUMBER" "$SPARKLE_FEED_URL" "$SPARKLE_ALPHA_FEED_URL" "$SPARKLE_PUBLIC_ED_KEY"
  powerlens_copy_app_icon "$INFO_PLIST" "$APP_RESOURCES"
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

require_packaging_inputs
powerlens_require_native_apple_silicon_host
kill_running_app
build_bundle
sign_bundle_for_local_run

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
