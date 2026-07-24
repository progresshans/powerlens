#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PowerLens"
APP_BUNDLE="${1:-$ROOT_DIR/dist/$APP_NAME.app}"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
EXPECTED_APP_ARCH="arm64"
STRICT="${STRICT:-0}"

fail_if_missing() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo "missing required path: $path" >&2
    exit 2
  fi
}

inspect_signature() {
  if codesign -dvvv "$APP_BUNDLE" >/tmp/powerlens-codesign.txt 2>&1; then
    echo "codesign: signed"
    cat /tmp/powerlens-codesign.txt
    return 0
  fi

  echo "codesign: unsigned or ad-hoc-only"
  cat /tmp/powerlens-codesign.txt
  return 1
}

inspect_gatekeeper() {
  if spctl -a -vv "$APP_BUNDLE" >/tmp/powerlens-spctl.txt 2>&1; then
    echo "spctl: accepted"
    cat /tmp/powerlens-spctl.txt
    return 0
  fi

  echo "spctl: not accepted yet"
  cat /tmp/powerlens-spctl.txt
  return 1
}

verify_main_executable_architecture() {
  local actual_archs

  if ! actual_archs="$(lipo -archs "$APP_BINARY" 2>/dev/null)"; then
    echo "unable to inspect executable architecture: $APP_BINARY" >&2
    return 1
  fi

  echo "architectures: $actual_archs"
  if [[ "$actual_archs" != "$EXPECTED_APP_ARCH" ]]; then
    echo "unexpected PowerLens executable architectures: $actual_archs" >&2
    echo "expected exactly: $EXPECTED_APP_ARCH" >&2
    return 1
  fi

  echo "architecture: Apple silicon only"
}

fail_if_missing "$APP_BUNDLE"
fail_if_missing "$INFO_PLIST"
fail_if_missing "$APP_BINARY"

echo "== Bundle Metadata =="
plutil -p "$INFO_PLIST"

echo
echo "== Executable =="
file "$APP_BINARY"
verify_main_executable_architecture

echo
echo "== Signature =="
signature_ok=0
if inspect_signature; then
  signature_ok=1
fi

echo
echo "== Entitlements =="
if codesign -d --entitlements :- "$APP_BUNDLE" 2>/tmp/powerlens-entitlements.err; then
  :
else
  cat /tmp/powerlens-entitlements.err
fi

echo
echo "== Gatekeeper =="
gatekeeper_ok=0
if inspect_gatekeeper; then
  gatekeeper_ok=1
fi

echo
echo "== Summary =="
if [[ "$signature_ok" -eq 1 && "$gatekeeper_ok" -eq 1 ]]; then
  echo "distribution-ready checks currently look good."
else
  echo "the app is not distribution-ready yet."
  echo "- expected at this stage: local bundle metadata is present"
  echo "- next missing step: Developer ID signing + hardened runtime + notarization"
fi

if [[ "$STRICT" == "1" && ( "$signature_ok" -ne 1 || "$gatekeeper_ok" -ne 1 ) ]]; then
  exit 1
fi
