#!/usr/bin/env bash
set -euo pipefail

TAG="${1:?usage: verify_release_tag.sh TAG EXPECTED_SHA TAG_ORIGIN RUN_ID}"
EXPECTED_SHA="${2:?usage: verify_release_tag.sh TAG EXPECTED_SHA TAG_ORIGIN RUN_ID}"
TAG_ORIGIN="${3:?usage: verify_release_tag.sh TAG EXPECTED_SHA TAG_ORIGIN RUN_ID}"
RUN_ID="${4:?usage: verify_release_tag.sh TAG EXPECTED_SHA TAG_ORIGIN RUN_ID}"

die() {
  echo "release tag verification: $*" >&2
  exit 2
}

tag_run_id() {
  local tag="$1"

  [[ "$(git cat-file -t "refs/tags/$tag" 2>/dev/null || true)" == "tag" ]] || return 1
  git cat-file -p "refs/tags/$tag" \
    | sed -n 's/^powerlens-run-id: \([0-9][0-9]*\)$/\1/p' \
    | tail -n 1
}

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-alpha\.[0-9]+)?$ ]]; then
  die "unsupported tag: $TAG"
fi

case "$TAG_ORIGIN" in
  event | reserved)
    ;;
  *)
    die "unsupported tag origin: $TAG_ORIGIN"
    ;;
esac

git fetch --force origin "refs/tags/$TAG:refs/tags/$TAG"

expected_commit="$(git rev-parse "${EXPECTED_SHA}^{commit}")"
actual_commit="$(git rev-list -n 1 "$TAG")"
if [[ "$actual_commit" != "$expected_commit" ]]; then
  die "$TAG points to $actual_commit, expected $expected_commit"
fi

if [[ "$TAG_ORIGIN" == "reserved" ]]; then
  owner_run_id="$(tag_run_id "$TAG" || true)"
  if [[ "$owner_run_id" != "$RUN_ID" ]]; then
    die "$TAG is owned by run ${owner_run_id:-unknown}, expected $RUN_ID"
  fi
fi

echo "$TAG verified at $actual_commit ($TAG_ORIGIN)"
