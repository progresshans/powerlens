#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:?usage: smoke_launch_app.sh /path/to/PowerLens.app}"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/PowerLens"

if [[ ! -x "$APP_BINARY" ]]; then
  echo "launch smoke: executable not found: $APP_BINARY" >&2
  exit 2
fi

SMOKE_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/powerlens-launch-smoke.XXXXXX")"
SMOKE_LOG="$SMOKE_STATE_DIR/powerlens.log"
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    for _ in {1..20}; do
      if ! kill -0 "$APP_PID" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "$APP_PID" 2>/dev/null; then
      kill -KILL "$APP_PID" 2>/dev/null || true
    fi
  fi
  if [[ -n "$APP_PID" ]]; then
    wait "$APP_PID" 2>/dev/null || true
  fi
  rm -rf "$SMOKE_STATE_DIR"
}
trap 'cleanup 2>/dev/null' EXIT

CFFIXED_USER_HOME="$SMOKE_STATE_DIR/user" "$APP_BINARY" >"$SMOKE_LOG" 2>&1 &
APP_PID="$!"

for _ in {1..20}; do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "launch smoke: PowerLens exited during startup" >&2
    sed -n '1,120p' "$SMOKE_LOG" >&2
    exit 1
  fi
  sleep 0.25
done

echo "launch smoke: PowerLens remained alive for 5 seconds"
