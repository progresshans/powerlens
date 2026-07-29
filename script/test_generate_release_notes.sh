#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT_DIR/Tests/Fixtures/ReleaseNotes/CHANGELOG.md"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/powerlens-release-notes-test.XXXXXX")"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

if "$ROOT_DIR/script/generate_release_notes.sh" \
  2.0.0 \
  "$TEST_DIR/stable-missing.md" \
  "$FIXTURE" \
  >"$TEST_DIR/stable-missing.log" 2>&1; then
  echo "release-note test: stable release unexpectedly used a fallback section" >&2
  exit 1
fi
grep -Fq \
  'release notes: CHANGELOG.md has no non-empty section for 2.0.0' \
  "$TEST_DIR/stable-missing.log"

"$ROOT_DIR/script/generate_release_notes.sh" \
  1.2.3 \
  "$TEST_DIR/stable.md" \
  "$FIXTURE"
grep -q '^# PowerLens 1.2.3$' "$TEST_DIR/stable.md"
grep -Fq 'Stable release note.' "$TEST_DIR/stable.md"
if grep -Fq 'Unreleased preview note.' "$TEST_DIR/stable.md"; then
  echo "release-note test: stable release included unreleased content" >&2
  exit 1
fi

"$ROOT_DIR/script/generate_release_notes.sh" \
  2.0.0-alpha.1 \
  "$TEST_DIR/alpha.md" \
  "$FIXTURE"
grep -q '^# PowerLens 2.0.0-alpha.1$' "$TEST_DIR/alpha.md"
grep -Fq 'Unreleased preview note.' "$TEST_DIR/alpha.md"

echo "release-note tests passed"
