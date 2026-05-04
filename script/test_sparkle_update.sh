#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/powerlens_packaging.sh"

APP_NAME="$POWERLENS_APP_NAME"
ENV_FILE="${POWERLENS_ENV_FILE:-$ROOT_DIR/.env}"
MODE="${1:-run}"
SERVER_PID=""

source_env_if_present() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi
}

source_env_if_present

HOST="${POWERLENS_SPARKLE_TEST_HOST:-127.0.0.1}"
PORT="${POWERLENS_SPARKLE_TEST_PORT:-18080}"
FEED_URL="http://$HOST:$PORT/appcast.xml"
TEST_ROOT="${POWERLENS_SPARKLE_TEST_DIR:-$ROOT_DIR/release/sparkle-local-test}"
FEED_DIR="$TEST_ROOT/feed"
BASE_DIR="$TEST_ROOT/base"
BASE_APP="$BASE_DIR/$APP_NAME.app"
BASE_VERSION="${POWERLENS_SPARKLE_TEST_BASE_VERSION:-0.9.1}"
BASE_BUILD="${POWERLENS_SPARKLE_TEST_BASE_BUILD:-1}"
UPDATE_VERSION="${POWERLENS_SPARKLE_TEST_UPDATE_VERSION:-0.9.2}"
UPDATE_BUILD="${POWERLENS_SPARKLE_TEST_UPDATE_BUILD:-2}"

usage() {
  cat <<EOF
usage: $0 [run|prepare-only|--help]

Builds a local Sparkle update smoke test:
  - base app:   $BASE_VERSION ($BASE_BUILD)
  - update app: $UPDATE_VERSION ($UPDATE_BUILD)
  - feed URL:   $FEED_URL

Environment overrides:
  POWERLENS_SPARKLE_TEST_BASE_VERSION
  POWERLENS_SPARKLE_TEST_BASE_BUILD
  POWERLENS_SPARKLE_TEST_UPDATE_VERSION
  POWERLENS_SPARKLE_TEST_UPDATE_BUILD
  POWERLENS_SPARKLE_TEST_PORT
  POWERLENS_SPARKLE_TEST_DIR
EOF
}

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}

require_local_update_inputs() {
  powerlens_require_file "$POWERLENS_SOURCE_INFO_PLIST"
  powerlens_require_file "$POWERLENS_ENTITLEMENTS"
  powerlens_require_file "$POWERLENS_SPARKLE_GENERATE_APPCAST_TOOL"

  if [[ -z "${POWERLENS_SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
    echo "missing POWERLENS_SPARKLE_PUBLIC_ED_KEY; add the Sparkle public key to .env first" >&2
    exit 2
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "missing python3; it is required for the local update feed server" >&2
    exit 2
  fi

  if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null; then
    echo "port $PORT is already in use; set POWERLENS_SPARKLE_TEST_PORT to another port" >&2
    exit 2
  fi
}

package_base_app() {
  echo "sparkle-test: packaging base app $BASE_VERSION ($BASE_BUILD)"
  POWERLENS_VERSION="$BASE_VERSION" \
    POWERLENS_BUILD="$BASE_BUILD" \
    POWERLENS_SPARKLE_FEED_URL="$FEED_URL" \
    POWERLENS_SPARKLE_GENERATE_APPCAST=0 \
    POWERLENS_SKIP_NOTARIZATION=1 \
    POWERLENS_CLEAN_BUILD=1 \
    "$ROOT_DIR/script/package_release.sh"

  rm -rf "$BASE_DIR"
  mkdir -p "$BASE_DIR"
  ditto --noqtn --noextattr "$ROOT_DIR/release/stage/$APP_NAME.app" "$BASE_APP"
}

package_update_appcast() {
  echo "sparkle-test: packaging update app $UPDATE_VERSION ($UPDATE_BUILD)"
  rm -rf "$FEED_DIR"
  mkdir -p "$FEED_DIR"

  POWERLENS_VERSION="$UPDATE_VERSION" \
    POWERLENS_BUILD="$UPDATE_BUILD" \
    POWERLENS_SPARKLE_FEED_URL="$FEED_URL" \
    POWERLENS_SPARKLE_GENERATE_APPCAST=1 \
    POWERLENS_SPARKLE_APPCAST_DIR="$FEED_DIR" \
    POWERLENS_SPARKLE_DOWNLOAD_URL_PREFIX="http://$HOST:$PORT/" \
    POWERLENS_SKIP_NOTARIZATION=1 \
    POWERLENS_CLEAN_BUILD=0 \
    "$ROOT_DIR/script/package_release.sh"

  powerlens_require_file "$FEED_DIR/appcast.xml"
  powerlens_require_file "$FEED_DIR/$APP_NAME-$UPDATE_VERSION.app.zip"
}

start_feed_server() {
  echo "sparkle-test: serving $FEED_DIR at $FEED_URL"
  (
    cd "$FEED_DIR"
    exec python3 -m http.server "$PORT" --bind "$HOST"
  ) &
  SERVER_PID="$!"
  sleep 1
}

open_base_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  echo "sparkle-test: opening $BASE_APP"
  /usr/bin/open -n "$BASE_APP"
}

case "$MODE" in
  --help|-h|help)
    usage
    exit 0
    ;;
  run|prepare-only)
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

trap cleanup EXIT INT TERM
require_local_update_inputs
rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT"
package_base_app
package_update_appcast

echo
echo "Sparkle local test artifacts:"
echo "- base app: $BASE_APP"
echo "- appcast:  $FEED_DIR/appcast.xml"
echo "- update:   $FEED_DIR/$APP_NAME-$UPDATE_VERSION.app.zip"

if [[ "$MODE" == "prepare-only" ]]; then
  echo
  echo "Run this to serve the feed manually:"
  echo "  cd \"$FEED_DIR\" && python3 -m http.server \"$PORT\" --bind \"$HOST\""
  exit 0
fi

start_feed_server
open_base_app

cat <<EOF

PowerLens $BASE_VERSION is running with a local Sparkle feed.

To test:
1. Open PowerLens Settings or the app menu.
2. Choose "Check for Updates...".
3. Confirm Sparkle offers $UPDATE_VERSION.

Press Ctrl-C here when finished.
EOF

wait "$SERVER_PID"
