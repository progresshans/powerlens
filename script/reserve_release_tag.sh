#!/usr/bin/env bash
set -euo pipefail

TAG="${1:?usage: reserve_release_tag.sh TAG EXPECTED_SHA RUN_ID}"
EXPECTED_SHA="${2:?usage: reserve_release_tag.sh TAG EXPECTED_SHA RUN_ID}"
RUN_ID="${3:?usage: reserve_release_tag.sh TAG EXPECTED_SHA RUN_ID}"

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

die() {
  echo "release tag reservation: $*" >&2
  exit 2
}

tag_exists() {
  git show-ref --verify --quiet "refs/tags/$1"
}

tag_run_id() {
  local tag="$1"

  [[ "$(git cat-file -t "refs/tags/$tag" 2>/dev/null || true)" == "tag" ]] || return 1
  git cat-file -p "refs/tags/$tag" \
    | sed -n 's/^powerlens-run-id: \([0-9][0-9]*\)$/\1/p' \
    | tail -n 1
}

remote_tag_exists() {
  [[ -n "$(git ls-remote --tags origin "refs/tags/$1")" ]]
}

fetch_tag() {
  local tag="$1"
  git fetch --force origin "refs/tags/$tag:refs/tags/$tag"
}

verify_owned_tag() {
  local tag="$1"
  local actual_commit owner_run_id

  actual_commit="$(git rev-list -n 1 "$tag")"
  if [[ "$actual_commit" != "$expected_commit" ]]; then
    die "$tag points to $actual_commit, expected $expected_commit"
  fi

  owner_run_id="$(tag_run_id "$tag" || true)"
  if [[ "$owner_run_id" != "$RUN_ID" ]]; then
    die "$tag is owned by run ${owner_run_id:-unknown}, expected $RUN_ID"
  fi
}

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-alpha\.[0-9]+)?$ ]]; then
  die "unsupported tag: $TAG"
fi
if [[ ! "$RUN_ID" =~ ^[0-9]+$ ]]; then
  die "invalid run ID: $RUN_ID"
fi

expected_commit="$(git rev-parse "${EXPECTED_SHA}^{commit}")"

if remote_tag_exists "$TAG"; then
  fetch_tag "$TAG"
  verify_owned_tag "$TAG"
  echo "Reusing $TAG reserved by run $RUN_ID"
  echo "tag_origin=reserved" >> "$GITHUB_OUTPUT"
  exit 0
fi

if tag_exists "$TAG"; then
  git tag -d "$TAG" >/dev/null
fi

git \
  -c user.name="github-actions[bot]" \
  -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  tag -a "$TAG" "$expected_commit" \
  -m "PowerLens release reservation" \
  -m "powerlens-run-id: $RUN_ID"

if git push origin "refs/tags/$TAG:refs/tags/$TAG"; then
  echo "Reserved $TAG for run $RUN_ID"
  echo "tag_origin=reserved" >> "$GITHUB_OUTPUT"
  exit 0
fi

# A failed push can be either a real collision or an ambiguous transport
# failure after the remote accepted the tag. Re-fetch and only recover a tag
# that has the expected commit and this workflow run's ownership marker.
git tag -d "$TAG" >/dev/null
if remote_tag_exists "$TAG"; then
  fetch_tag "$TAG"
  verify_owned_tag "$TAG"
  echo "Recovered $TAG after an ambiguous push result"
  echo "tag_origin=reserved" >> "$GITHUB_OUTPUT"
  exit 0
fi

die "failed to reserve $TAG and no remote tag appeared"
