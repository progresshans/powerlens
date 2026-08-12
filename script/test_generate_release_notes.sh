#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT_DIR/Tests/Fixtures/ReleaseNotes/CHANGELOG.md"
EMPTY_FIXTURE="$ROOT_DIR/Tests/Fixtures/ReleaseNotes/EMPTY_CHANGELOG.md"
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

if "$ROOT_DIR/script/generate_release_notes.sh" \
  2.0.0-alpha.1 \
  "$TEST_DIR/empty-alpha-strict.md" \
  "$EMPTY_FIXTURE" \
  >"$TEST_DIR/empty-alpha-strict.log" 2>&1; then
  echo "release-note test: strict alpha unexpectedly accepted empty notes" >&2
  exit 1
fi
grep -Fq \
  'release notes: CHANGELOG.md has no non-empty section for 2.0.0-alpha.1, 2.0.0, Unreleased' \
  "$TEST_DIR/empty-alpha-strict.log"

"$ROOT_DIR/script/generate_release_notes.sh" \
  2.0.0-alpha.1 \
  "$TEST_DIR/empty-automatic-alpha.md" \
  "$EMPTY_FIXTURE" \
  allow-empty-alpha
grep -q '^# PowerLens 2.0.0-alpha.1$' "$TEST_DIR/empty-automatic-alpha.md"
grep -Fq \
  'This alpha preview contains the latest reviewed changes from `develop`.' \
  "$TEST_DIR/empty-automatic-alpha.md"

if "$ROOT_DIR/script/generate_release_notes.sh" \
  2.0.0 \
  "$TEST_DIR/empty-stable-permissive.md" \
  "$EMPTY_FIXTURE" \
  allow-empty-alpha \
  >"$TEST_DIR/empty-stable-permissive.log" 2>&1; then
  echo "release-note test: stable release accepted the alpha-only fallback" >&2
  exit 1
fi

echo "release-note tests passed"
