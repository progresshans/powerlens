#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME is required}"
: "${GITHUB_REF_TYPE:?GITHUB_REF_TYPE is required}"
: "${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

DISPATCH_VERSION="${DISPATCH_VERSION:-}"
DISPATCH_CHANNEL="${DISPATCH_CHANNEL:-}"
ALPHA_BASE_VERSION="${ALPHA_BASE_VERSION:-}"
MANUAL_NOTES_VALIDATED="${MANUAL_NOTES_VALIDATED:-}"

die() {
  echo "release metadata: $*" >&2
  exit 2
}

refresh_tags() {
  git fetch --force --tags origin
}

tag_exists() {
  git show-ref --verify --quiet "refs/tags/$1"
}

tag_commit() {
  git rev-list -n 1 "$1"
}

tag_run_id() {
  local tag="$1"

  [[ "$(git cat-file -t "refs/tags/$tag" 2>/dev/null || true)" == "tag" ]] || return 1
  git cat-file -p "refs/tags/$tag" \
    | sed -n 's/^powerlens-run-id: \([0-9][0-9]*\)$/\1/p' \
    | tail -n 1
}

verify_tag_commit() {
  local tag="$1"
  local actual_commit
  actual_commit="$(tag_commit "$tag")"

  if [[ "$actual_commit" != "$source_commit" ]]; then
    die "$tag points to $actual_commit, expected $source_commit"
  fi
}

create_owned_tag() {
  local tag="$1"

  git \
    -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    tag -a "$tag" "$source_commit" \
    -m "PowerLens release reservation" \
    -m "powerlens-run-id: $GITHUB_RUN_ID"
}

validate_version() {
  local candidate="$1"
  if [[ ! "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-alpha\.[0-9]+)?$ ]]; then
    die "unsupported release version: $candidate (expected 0.9.3 or 0.9.3-alpha.1)"
  fi
}

validate_alpha_base_version() {
  local candidate="$1"
  if [[ ! "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "invalid alpha base version: $candidate (expected 0.9.3, 0.10.0, or 1.0.0)"
  fi
}

version_is_greater_than() {
  local candidate="$1"
  local baseline="$2"
  local candidate_major candidate_minor candidate_patch
  local baseline_major baseline_minor baseline_patch

  IFS=. read -r candidate_major candidate_minor candidate_patch <<< "$candidate"
  IFS=. read -r baseline_major baseline_minor baseline_patch <<< "$baseline"

  if (( 10#$candidate_major != 10#$baseline_major )); then
    (( 10#$candidate_major > 10#$baseline_major ))
  elif (( 10#$candidate_minor != 10#$baseline_minor )); then
    (( 10#$candidate_minor > 10#$baseline_minor ))
  else
    (( 10#$candidate_patch > 10#$baseline_patch ))
  fi
}

latest_stable_tag() {
  git tag --list 'v*' --sort=-v:refname \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | head -n 1 \
    || true
}

latest_alpha_tag() {
  git tag --list 'v*-alpha.*' --sort=-v:refname \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+$' \
    | head -n 1 \
    || true
}

next_patch_alpha_base_version() {
  local stable_tag="$1"

  if [[ -z "$stable_tag" ]]; then
    echo "0.1.0"
    return
  fi

  local stable_version="${stable_tag#v}"
  local major minor patch
  IFS=. read -r major minor patch <<< "$stable_version"
  echo "$major.$minor.$((10#$patch + 1))"
}

next_alpha_sequence() {
  local base_version="$1"
  local prefix="v${base_version}-alpha."
  local highest=0
  local tag suffix

  while IFS= read -r tag; do
    suffix="${tag#"$prefix"}"
    if [[ "$suffix" =~ ^[0-9]+$ ]] && (( 10#$suffix > highest )); then
      highest=$((10#$suffix))
    fi
  done < <(git tag --list "${prefix}*")

  echo "$((highest + 1))"
}

find_run_owned_alpha_tag() {
  local found=""
  local tag owner

  while IFS= read -r tag; do
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+$ ]] || continue
    owner="$(tag_run_id "$tag" || true)"
    [[ "$owner" == "$GITHUB_RUN_ID" ]] || continue

    if [[ -n "$found" ]]; then
      die "run $GITHUB_RUN_ID owns more than one alpha tag: $found and $tag"
    fi
    verify_tag_commit "$tag"
    found="$tag"
  done < <(git tag --list 'v*-alpha.*')

  echo "$found"
}

reserve_automatic_alpha_tag() {
  local recovered_tag
  recovered_tag="$(find_run_owned_alpha_tag)"
  if [[ -n "$recovered_tag" ]]; then
    tag="$recovered_tag"
    version="${tag#v}"
    tag_origin="reserved"
    echo "Reusing $tag reserved by run $GITHUB_RUN_ID" >&2
    return
  fi

  local stable_tag stable_version alpha_tag alpha_version alpha_base_version
  local base_version alpha_sequence candidate attempt owner
  stable_tag="$(latest_stable_tag)"
  stable_version="${stable_tag#v}"
  alpha_tag="$(latest_alpha_tag)"
  alpha_version="${alpha_tag#v}"
  alpha_base_version="${alpha_version%-alpha.*}"
  base_version="${ALPHA_BASE_VERSION:-$(next_patch_alpha_base_version "$stable_tag")}"
  validate_alpha_base_version "$base_version"

  if [[ -n "$stable_version" ]] && ! version_is_greater_than "$base_version" "$stable_version"; then
    die "alpha base $base_version must be newer than latest stable $stable_version"
  fi
  if [[ -n "$alpha_base_version" ]] \
    && version_is_greater_than "$alpha_base_version" "$base_version"; then
    die "alpha base $base_version must not precede latest alpha base $alpha_base_version"
  fi

  for attempt in {1..10}; do
    alpha_sequence="$(next_alpha_sequence "$base_version")"
    candidate="v${base_version}-alpha.${alpha_sequence}"
    create_owned_tag "$candidate"

    if git push origin "refs/tags/$candidate:refs/tags/$candidate"; then
      tag="$candidate"
      version="${tag#v}"
      tag_origin="reserved"
      echo "Reserved $tag for run $GITHUB_RUN_ID" >&2
      return
    fi

    git tag -d "$candidate" >/dev/null
    refresh_tags
    if ! tag_exists "$candidate"; then
      die "failed to reserve $candidate and no competing remote tag appeared"
    fi

    owner="$(tag_run_id "$candidate" || true)"
    if [[ "$owner" == "$GITHUB_RUN_ID" ]]; then
      verify_tag_commit "$candidate"
      tag="$candidate"
      version="${tag#v}"
      tag_origin="reserved"
      echo "Recovered $tag after an ambiguous push result" >&2
      return
    fi

    echo "Reservation collision on $candidate; retrying" >&2
  done

  die "could not reserve an alpha tag after 10 attempts"
}

verify_event_tag() {
  if ! tag_exists "$tag"; then
    die "tag event ref $tag is missing after fetching remote tags"
  fi

  verify_tag_commit "$tag"
  tag_origin="event"
}

source_commit="$(git rev-parse "${GITHUB_SHA}^{commit}")"
refresh_tags

if [[ "$GITHUB_EVENT_NAME" == "push" \
  && "$GITHUB_REF_TYPE" == "tag" ]]; then
  release_kind="tag"
  version="${GITHUB_REF_NAME#v}"
  tag="$GITHUB_REF_NAME"
  if [[ "$version" == *"-alpha."* ]]; then
    channel="alpha"
  else
    channel="stable"
  fi
elif [[ "$GITHUB_EVENT_NAME" == "push" \
  && "$GITHUB_REF_TYPE" == "branch" \
  && "$GITHUB_REF_NAME" == "develop" \
  && -z "$DISPATCH_VERSION" ]]; then
  release_kind="automatic"
  channel="alpha"
  reserve_automatic_alpha_tag
else
  release_kind="manual"
  version="${DISPATCH_VERSION:?workflow_dispatch requires a version}"
  tag="v${version}"
  channel="${DISPATCH_CHANNEL:-stable}"
fi

validate_version "$version"

if [[ "$version" == *"-alpha."* && "$channel" != "alpha" ]]; then
  die "alpha versions must use the alpha channel"
fi
if [[ "$version" != *"-alpha."* && "$channel" != "stable" ]]; then
  die "stable versions must use the stable channel"
fi
if [[ "$release_kind" == "manual" && "$MANUAL_NOTES_VALIDATED" != "true" ]]; then
  die "manual release notes must be validated before release metadata is accepted"
fi

if [[ "$release_kind" == "tag" ]]; then
  verify_event_tag
elif [[ "$release_kind" == "manual" ]]; then
  tag_origin="pending"
fi

case "$channel" in
  stable)
    appcast_path="docs/appcast.xml"
    prerelease="false"
    latest="true"
    ;;
  alpha)
    appcast_path="docs/appcast-alpha.xml"
    prerelease="true"
    latest="false"
    ;;
  *)
    die "unsupported channel: $channel"
    ;;
esac

if [[ "$release_kind" == "automatic" ]]; then
  release_notes_mode="allow-empty-alpha"
else
  release_notes_mode="require-notes"
fi

{
  echo "version=$version"
  echo "tag=$tag"
  echo "channel=$channel"
  echo "appcast_path=$appcast_path"
  echo "prerelease=$prerelease"
  echo "latest=$latest"
  echo "release_kind=$release_kind"
  echo "tag_origin=$tag_origin"
  echo "release_notes_mode=$release_notes_mode"
  echo "source_sha=$source_commit"
  echo "download_url_prefix=https://github.com/${GITHUB_REPOSITORY}/releases/download/${tag}/"
} >> "$GITHUB_OUTPUT"

echo "PowerLens $version ($channel, $release_kind) -> $tag"
