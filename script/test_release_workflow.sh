#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW_PATH="$ROOT_DIR/.github/workflows/release.yml"
RESOLVER="$ROOT_DIR/script/resolve_release_metadata.sh"
TAG_RESERVER="$ROOT_DIR/script/reserve_release_tag.sh"
TAG_VERIFIER="$ROOT_DIR/script/verify_release_tag.sh"
PUBLISHER="$ROOT_DIR/script/publish_github_release.sh"
APPCAST_VALIDATOR="$ROOT_DIR/script/validate_appcast_progression.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/powerlens-release-workflow-test.XXXXXX")"
REMOTE_REPOSITORY="$TEST_DIR/remote.git"
WORK_REPOSITORY="$TEST_DIR/repository"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

ruby -ryaml - "$WORKFLOW_PATH" <<'RUBY'
workflow_path = ARGV.fetch(0)
workflow = YAML.safe_load(File.read(workflow_path), aliases: false)
triggers = workflow["on"] || workflow[true]
abort "release workflow: missing on trigger" unless triggers.is_a?(Hash)

push = triggers["push"]
abort "release workflow: missing push trigger" unless push.is_a?(Hash)
abort "release workflow: expected develop push trigger" unless Array(push["branches"]) == ["develop"]
abort "release workflow: expected explicit v* tag releases" unless Array(push["tags"]) == ["v*"]

request_concurrency = workflow["concurrency"]
abort "release workflow: missing request concurrency" unless request_concurrency.is_a?(Hash)
expected_request_group =
  "release-request-${{ github.event_name == 'push' && github.ref == " \
  "'refs/heads/develop' && 'develop' || github.run_id }}"
unless request_concurrency["group"] == expected_request_group
  abort "release workflow: automatic develop requests must coalesce independently"
end
unless request_concurrency["cancel-in-progress"] == false
  abort "release workflow: a running automatic alpha must not be canceled"
end
if request_concurrency.key?("queue")
  abort "release workflow: automatic request concurrency must retain latest-pending semantics"
end

jobs = workflow["jobs"]
build = jobs["build"]
publish = jobs["publish"]
abort "release workflow: missing build job" unless build.is_a?(Hash)
abort "release workflow: missing publish job" unless publish.is_a?(Hash)
abort "release workflow: build must use protected release environment" unless build["environment"] == "release"
abort "release workflow: publish must depend on build" unless publish["needs"] == "build"

publish_concurrency = publish["concurrency"]
unless publish_concurrency == {
  "group" => "publish-release",
  "cancel-in-progress" => false,
  "queue" => "max",
}
  abort "release workflow: publication must use one durable global queue"
end

publish_environment = publish["environment"]
unless publish_environment.is_a?(Hash) && publish_environment["name"] == "github-pages"
  abort "release workflow: publication must deploy through the github-pages environment"
end

build_steps = build["steps"]
publish_steps = publish["steps"]
abort "release workflow: missing build steps" unless build_steps.is_a?(Array)
abort "release workflow: missing publish steps" unless publish_steps.is_a?(Array)

manual_notes_index =
  build_steps.index { |step| step["name"] == "Validate manually dispatched release notes" }
metadata_index =
  build_steps.index { |step| step["name"] == "Resolve release metadata" }
unless manual_notes_index && metadata_index && manual_notes_index < metadata_index
  abort "release workflow: manual notes must be validated before metadata resolution"
end
manual_notes_step = build_steps.fetch(manual_notes_index)
unless manual_notes_step["if"] == "github.event_name == 'workflow_dispatch'"
  abort "release workflow: manual note preflight must only run for dispatches"
end
unless manual_notes_step["run"].include?("require-notes") &&
    manual_notes_step["run"].include?("validated=true")
  abort "release workflow: manual note preflight must be strict and record success"
end

metadata_step = build_steps.fetch(metadata_index)
unless metadata_step && metadata_step["run"] == "./script/resolve_release_metadata.sh"
  abort "release workflow: metadata must use the tested resolver"
end
unless metadata_step.dig("env", "MANUAL_NOTES_VALIDATED") ==
    "${{ steps.manual_notes.outputs.validated }}"
  abort "release workflow: resolver must require the manual note preflight output"
end

release_notes_step = build_steps.find { |step| step["name"] == "Create release notes" }
unless release_notes_step &&
    release_notes_step["if"] == "github.event_name != 'workflow_dispatch'"
  abort "release workflow: manual notes must not be regenerated after preflight"
end

tag_verification_step =
  build_steps.find { |step| step["name"] == "Verify reserved release tag" }
unless tag_verification_step &&
    tag_verification_step["if"] == "steps.meta.outputs.tag_origin != 'pending'"
  abort "release workflow: a pending manual tag must not be verified during build"
end

upload_step = build_steps.find { |step| step["name"] == "Upload publication artifact" }
unless upload_step&.dig("with", "overwrite") == true
  abort "release workflow: full reruns must replace the run-scoped build artifact"
end

release_step = publish_steps.find { |step| step["name"] == "Publish GitHub Release" }
unless release_step && release_step["run"] == "./script/publish_github_release.sh"
  abort "release workflow: GitHub Releases must use the ownership-checking publisher"
end

pages_prepare_index =
  publish_steps.index { |step| step["name"] == "Prepare GitHub Pages artifact" }
manual_reservation_index =
  publish_steps.index { |step| step["name"] == "Reserve manually dispatched release tag" }
release_index =
  publish_steps.index { |step| step["name"] == "Publish GitHub Release" }
unless pages_prepare_index && manual_reservation_index && release_index &&
    pages_prepare_index < manual_reservation_index &&
    manual_reservation_index < release_index
  abort "release workflow: feed validation must precede manual tag reservation and publication"
end
pages_prepare = publish_steps.fetch(pages_prepare_index)
unless pages_prepare["run"].include?("./script/validate_appcast_progression.sh")
  abort "release workflow: Pages preparation must prevent appcast rollback"
end

manual_reservation = publish_steps.fetch(manual_reservation_index)
unless manual_reservation["if"] == "steps.meta.outputs.release_kind == 'manual'" &&
    manual_reservation["run"].include?("./script/reserve_release_tag.sh")
  abort "release workflow: only manual dispatches may reserve a tag during publication"
end

metadata_validation =
  publish_steps.find { |step| step["name"] == "Validate publication metadata" }
unless metadata_validation &&
    metadata_validation["run"].include?("manual:pending") &&
    metadata_validation["run"].include?("automatic:reserved") &&
    metadata_validation["run"].include?("tag:event")
  abort "release workflow: publication metadata must enforce release-kind tag ownership"
end

unless release_step.dig("env", "TAG_ORIGIN") ==
    "${{ steps.manual_tag.outputs.tag_origin || steps.meta.outputs.tag_origin }}"
  abort "release workflow: publisher must use the manual reservation output"
end

pages_upload = publish_steps.find { |step| step["name"] == "Upload GitHub Pages artifact" }
pages_deploy = publish_steps.find { |step| step["name"] == "Deploy GitHub Pages" }
abort "release workflow: missing Pages upload" unless pages_upload
abort "release workflow: missing Pages deployment" unless pages_deploy
unless pages_upload.dig("with", "name") == "github-pages-${{ github.run_id }}-${{ github.run_attempt }}"
  abort "release workflow: Pages artifacts must be unique per rerun attempt"
end
unless pages_deploy.dig("with", "artifact_name") == pages_upload.dig("with", "name")
  abort "release workflow: Pages deployment must select the attempt-scoped artifact"
end
RUBY

write_appcast_fixture() {
  local path="$1"
  shift

  {
    echo '<?xml version="1.0" encoding="utf-8"?>'
    echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
    echo '  <channel>'
    for version in "$@"; do
      echo '    <item>'
      printf '      <sparkle:shortVersionString>%s</sparkle:shortVersionString>\n' \
        "$version"
      echo '    </item>'
    done
    echo '  </channel>'
    echo '</rss>'
  } > "$path"
}

write_appcast_fixture "$TEST_DIR/empty-appcast.xml"
"$APPCAST_VALIDATOR" \
  "$TEST_DIR/empty-appcast.xml" \
  0.9.3-alpha.1 \
  alpha \
  >/dev/null

write_appcast_fixture "$TEST_DIR/alpha-appcast.xml" 0.9.3-alpha.7
"$APPCAST_VALIDATOR" \
  "$TEST_DIR/alpha-appcast.xml" \
  0.9.3-alpha.8 \
  alpha \
  >/dev/null
"$APPCAST_VALIDATOR" \
  "$TEST_DIR/alpha-appcast.xml" \
  0.9.3-alpha.7 \
  alpha \
  >/dev/null
if "$APPCAST_VALIDATOR" \
  "$TEST_DIR/alpha-appcast.xml" \
  0.9.3-alpha.6 \
  alpha \
  >"$TEST_DIR/alpha-rollback.log" 2>&1; then
  echo "release workflow test: appcast validator allowed an alpha rollback" >&2
  exit 1
fi
grep -Fq \
  "refusing to replace alpha 0.9.3-alpha.7 with older 0.9.3-alpha.6" \
  "$TEST_DIR/alpha-rollback.log"

write_appcast_fixture "$TEST_DIR/stable-appcast.xml" 0.9.2
"$APPCAST_VALIDATOR" \
  "$TEST_DIR/stable-appcast.xml" \
  0.9.3 \
  stable \
  >/dev/null
if "$APPCAST_VALIDATOR" \
  "$TEST_DIR/stable-appcast.xml" \
  0.9.1 \
  stable \
  >"$TEST_DIR/stable-rollback.log" 2>&1; then
  echo "release workflow test: appcast validator allowed a stable rollback" >&2
  exit 1
fi
grep -Fq \
  "refusing to replace stable 0.9.2 with older 0.9.1" \
  "$TEST_DIR/stable-rollback.log"

if "$APPCAST_VALIDATOR" \
  "$TEST_DIR/alpha-appcast.xml" \
  0.9.3 \
  stable \
  >"$TEST_DIR/channel-mismatch.log" 2>&1; then
  echo "release workflow test: appcast validator accepted the wrong channel" >&2
  exit 1
fi
grep -Fq \
  "'0.9.3-alpha.7' is not a valid stable version" \
  "$TEST_DIR/channel-mismatch.log"

git init --bare -q "$REMOTE_REPOSITORY"
git init -q "$WORK_REPOSITORY"
git -C "$WORK_REPOSITORY" checkout -q -b develop
git -C "$WORK_REPOSITORY" \
  -c user.name="PowerLens Tests" \
  -c user.email="tests@powerlens.invalid" \
  commit --allow-empty -q -m "stable fixture"
git -C "$WORK_REPOSITORY" remote add origin "$REMOTE_REPOSITORY"

stable_source="$(git -C "$WORK_REPOSITORY" rev-parse HEAD)"
git -C "$WORK_REPOSITORY" tag v0.9.2 "$stable_source"
git -C "$WORK_REPOSITORY" tag v0.9.2-alpha.99 "$stable_source"
git -C "$WORK_REPOSITORY" tag v0.9.3-alpha.6 "$stable_source"
git -C "$WORK_REPOSITORY" tag v0.9.3-alpha.7 "$stable_source"
git -C "$WORK_REPOSITORY" push -q origin develop --tags

git -C "$WORK_REPOSITORY" \
  -c user.name="PowerLens Tests" \
  -c user.email="tests@powerlens.invalid" \
  commit --allow-empty -q -m "automatic alpha fixture"
automatic_source="$(git -C "$WORK_REPOSITORY" rev-parse HEAD)"
git -C "$WORK_REPOSITORY" push -q origin develop

run_resolver() {
  local name="$1"
  local event_name="$2"
  local ref_type="$3"
  local ref_name="$4"
  local source_sha="$5"
  local run_id="$6"
  local dispatch_version="$7"
  local dispatch_channel="$8"
  local alpha_base_version="$9"
  local manual_notes_validated="${10:-}"
  local output_path="$TEST_DIR/$name.output"
  local log_path="$TEST_DIR/$name.log"

  (
    cd "$WORK_REPOSITORY"
    GITHUB_EVENT_NAME="$event_name" \
      GITHUB_REF_TYPE="$ref_type" \
      GITHUB_REF_NAME="$ref_name" \
      GITHUB_SHA="$source_sha" \
      GITHUB_RUN_ID="$run_id" \
      GITHUB_REPOSITORY="progresshans/powerlens" \
      GITHUB_OUTPUT="$output_path" \
      DISPATCH_VERSION="$dispatch_version" \
      DISPATCH_CHANNEL="$dispatch_channel" \
      ALPHA_BASE_VERSION="$alpha_base_version" \
      MANUAL_NOTES_VALIDATED="$manual_notes_validated" \
      "$RESOLVER"
  ) >"$log_path" 2>&1
}

run_tag_reserver() {
  local name="$1"
  local tag="$2"
  local source_sha="$3"
  local run_id="$4"
  local output_path="$TEST_DIR/$name.output"
  local log_path="$TEST_DIR/$name.log"

  (
    cd "$WORK_REPOSITORY"
    GITHUB_OUTPUT="$output_path" \
      "$TAG_RESERVER" "$tag" "$source_sha" "$run_id"
  ) >"$log_path" 2>&1
}

assert_output() {
  local output_path="$1"
  shift

  for expected in "$@"; do
    grep -Fqx "$expected" "$output_path"
  done
}

run_resolver \
  automatic-first \
  push \
  branch \
  develop \
  "$automatic_source" \
  1001 \
  "" \
  "" \
  ""
assert_output \
  "$TEST_DIR/automatic-first.output" \
  "version=0.9.3-alpha.8" \
  "tag=v0.9.3-alpha.8" \
  "channel=alpha" \
  "release_kind=automatic" \
  "tag_origin=reserved" \
  "release_notes_mode=allow-empty-alpha" \
  "source_sha=$automatic_source"
git -C "$WORK_REPOSITORY" fetch -q --force --tags origin
grep -Fqx \
  "powerlens-run-id: 1001" \
  < <(git -C "$WORK_REPOSITORY" cat-file -p refs/tags/v0.9.3-alpha.8)

run_resolver \
  automatic-rerun \
  push \
  branch \
  develop \
  "$automatic_source" \
  1001 \
  "" \
  "" \
  ""
assert_output \
  "$TEST_DIR/automatic-rerun.output" \
  "version=0.9.3-alpha.8" \
  "tag=v0.9.3-alpha.8"

(
  cd "$WORK_REPOSITORY"
  "$TAG_VERIFIER" \
    v0.9.3-alpha.8 \
    "$automatic_source" \
    reserved \
    1001
)

CONCURRENT_REPOSITORY_A="$TEST_DIR/concurrent-a"
CONCURRENT_REPOSITORY_B="$TEST_DIR/concurrent-b"
git clone -q --branch develop "$REMOTE_REPOSITORY" "$CONCURRENT_REPOSITORY_A"
git clone -q --branch develop "$REMOTE_REPOSITORY" "$CONCURRENT_REPOSITORY_B"

run_concurrent_resolver() {
  local repository="$1"
  local run_id="$2"
  local output_path="$3"
  local log_path="$4"

  (
    cd "$repository"
    GITHUB_EVENT_NAME=push \
      GITHUB_REF_TYPE=branch \
      GITHUB_REF_NAME=develop \
      GITHUB_SHA="$automatic_source" \
      GITHUB_RUN_ID="$run_id" \
      GITHUB_REPOSITORY="progresshans/powerlens" \
      GITHUB_OUTPUT="$output_path" \
      DISPATCH_VERSION="" \
      DISPATCH_CHANNEL="" \
      ALPHA_BASE_VERSION="" \
      "$RESOLVER"
  ) >"$log_path" 2>&1
}

run_concurrent_resolver \
  "$CONCURRENT_REPOSITORY_A" \
  1101 \
  "$TEST_DIR/concurrent-a.output" \
  "$TEST_DIR/concurrent-a.log" &
concurrent_pid_a=$!
run_concurrent_resolver \
  "$CONCURRENT_REPOSITORY_B" \
  1102 \
  "$TEST_DIR/concurrent-b.output" \
  "$TEST_DIR/concurrent-b.log" &
concurrent_pid_b=$!

concurrent_failed=0
wait "$concurrent_pid_a" || concurrent_failed=1
wait "$concurrent_pid_b" || concurrent_failed=1
if (( concurrent_failed != 0 )); then
  cat "$TEST_DIR/concurrent-a.log" >&2
  cat "$TEST_DIR/concurrent-b.log" >&2
  echo "release workflow test: concurrent reservations did not both complete" >&2
  exit 1
fi

concurrent_tags="$(
  {
    sed -n 's/^tag=//p' "$TEST_DIR/concurrent-a.output"
    sed -n 's/^tag=//p' "$TEST_DIR/concurrent-b.output"
  } | sort
)"
expected_concurrent_tags=$'v0.9.3-alpha.10\nv0.9.3-alpha.9'
if [[ "$concurrent_tags" != "$expected_concurrent_tags" ]]; then
  echo "release workflow test: concurrent reservations were not unique" >&2
  printf 'expected:\n%s\nactual:\n%s\n' \
    "$expected_concurrent_tags" \
    "$concurrent_tags" \
    >&2
  exit 1
fi

git -C "$WORK_REPOSITORY" fetch -q --force --tags origin
grep -Fqx \
  "powerlens-run-id: 1101" \
  < <(git -C "$WORK_REPOSITORY" cat-file -p \
    "refs/tags/$(sed -n 's/^tag=//p' "$TEST_DIR/concurrent-a.output")")
grep -Fqx \
  "powerlens-run-id: 1102" \
  < <(git -C "$WORK_REPOSITORY" cat-file -p \
    "refs/tags/$(sed -n 's/^tag=//p' "$TEST_DIR/concurrent-b.output")")

git -C "$WORK_REPOSITORY" \
  -c user.name="PowerLens Tests" \
  -c user.email="tests@powerlens.invalid" \
  commit --allow-empty -q -m "new alpha base fixture"
new_base_source="$(git -C "$WORK_REPOSITORY" rev-parse HEAD)"
git -C "$WORK_REPOSITORY" push -q origin develop

run_resolver \
  automatic-new-base \
  push \
  branch \
  develop \
  "$new_base_source" \
  1002 \
  "" \
  "" \
  0.10.0
assert_output \
  "$TEST_DIR/automatic-new-base.output" \
  "version=0.10.0-alpha.1" \
  "tag=v0.10.0-alpha.1"

if run_resolver \
  regressed-alpha-base \
  push \
  branch \
  develop \
  "$new_base_source" \
  1004 \
  "" \
  "" \
  0.9.3; then
  echo "release workflow test: accepted an alpha base older than the latest alpha" >&2
  exit 1
fi
grep -Fq \
  "alpha base 0.9.3 must not precede latest alpha base 0.10.0" \
  "$TEST_DIR/regressed-alpha-base.log"

if run_resolver \
  stale-alpha-base \
  push \
  branch \
  develop \
  "$new_base_source" \
  1003 \
  "" \
  "" \
  0.9.2; then
  echo "release workflow test: accepted an alpha base at the latest stable version" >&2
  exit 1
fi
grep -Fq \
  "alpha base 0.9.2 must be newer than latest stable 0.9.2" \
  "$TEST_DIR/stale-alpha-base.log"

git -C "$WORK_REPOSITORY" \
  -c user.name="PowerLens Tests" \
  -c user.email="tests@powerlens.invalid" \
  commit --allow-empty -q -m "manual stable fixture"
manual_source="$(git -C "$WORK_REPOSITORY" rev-parse HEAD)"
git -C "$WORK_REPOSITORY" push -q origin develop

if run_resolver \
  manual-without-note-preflight \
  workflow_dispatch \
  branch \
  main \
  "$manual_source" \
  2000 \
  0.9.3 \
  stable \
  "" \
  ""; then
  echo "release workflow test: manual dispatch skipped note preflight" >&2
  exit 1
fi
grep -Fq \
  "manual release notes must be validated before release metadata is accepted" \
  "$TEST_DIR/manual-without-note-preflight.log"
if git ls-remote --exit-code --tags "$REMOTE_REPOSITORY" \
  refs/tags/v0.9.3 >/dev/null 2>&1; then
  echo "release workflow test: failed manual preflight still reserved a tag" >&2
  exit 1
fi

run_resolver \
  manual-stable \
  workflow_dispatch \
  branch \
  main \
  "$manual_source" \
  2001 \
  0.9.3 \
  stable \
  "" \
  true
assert_output \
  "$TEST_DIR/manual-stable.output" \
  "version=0.9.3" \
  "tag=v0.9.3" \
  "channel=stable" \
  "release_kind=manual" \
  "tag_origin=pending" \
  "release_notes_mode=require-notes"
if git ls-remote --exit-code --tags "$REMOTE_REPOSITORY" \
  refs/tags/v0.9.3 >/dev/null 2>&1; then
  echo "release workflow test: metadata resolution reserved a manual tag" >&2
  exit 1
fi

run_resolver \
  manual-stable-rerun \
  workflow_dispatch \
  branch \
  main \
  "$manual_source" \
  2001 \
  0.9.3 \
  stable \
  "" \
  true
assert_output \
  "$TEST_DIR/manual-stable-rerun.output" \
  "tag_origin=pending"

run_tag_reserver \
  manual-stable-reservation \
  v0.9.3 \
  "$manual_source" \
  2001
assert_output \
  "$TEST_DIR/manual-stable-reservation.output" \
  "tag_origin=reserved"

run_tag_reserver \
  manual-stable-reservation-rerun \
  v0.9.3 \
  "$manual_source" \
  2001
assert_output \
  "$TEST_DIR/manual-stable-reservation-rerun.output" \
  "tag_origin=reserved"

if run_tag_reserver \
  manual-stable-reservation-other-run \
  v0.9.3 \
  "$manual_source" \
  2002; then
  echo "release workflow test: another run reused an owned manual tag" >&2
  exit 1
fi
grep -Fq \
  "v0.9.3 is owned by run 2001, expected 2002" \
  "$TEST_DIR/manual-stable-reservation-other-run.log"

git -C "$WORK_REPOSITORY" \
  -c user.name="PowerLens Tests" \
  -c user.email="tests@powerlens.invalid" \
  commit --allow-empty -q -m "explicit tag fixture"
tag_source="$(git -C "$WORK_REPOSITORY" rev-parse HEAD)"
git -C "$WORK_REPOSITORY" tag v0.9.4 "$tag_source"
git -C "$WORK_REPOSITORY" push -q origin develop refs/tags/v0.9.4

run_resolver \
  stable-tag \
  push \
  tag \
  v0.9.4 \
  "$tag_source" \
  3001 \
  "" \
  "" \
  ""
assert_output \
  "$TEST_DIR/stable-tag.output" \
  "version=0.9.4" \
  "tag=v0.9.4" \
  "channel=stable" \
  "release_kind=tag" \
  "tag_origin=event"

if run_resolver \
  stable-tag-wrong-source \
  push \
  tag \
  v0.9.4 \
  "$manual_source" \
  3002 \
  "" \
  "" \
  ""; then
  echo "release workflow test: accepted a tag that points to another commit" >&2
  exit 1
fi
grep -Fq \
  "v0.9.4 points to $tag_source, expected $manual_source" \
  "$TEST_DIR/stable-tag-wrong-source.log"

FAKE_GH_BIN="$TEST_DIR/fake-gh-bin"
FAKE_GH_STATE="$TEST_DIR/fake-gh-state"
mkdir -p "$FAKE_GH_BIN" "$FAKE_GH_STATE"
cat > "$FAKE_GH_BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

: "${FAKE_GH_STATE:?}"
printf '%s\n' "$*" >> "$FAKE_GH_STATE/calls.log"

if [[ "$1" != "release" ]]; then
  exit 2
fi

case "$2" in
  view)
    [[ -f "$FAKE_GH_STATE/exists" ]] || exit 1
    if [[ " $* " == *" --json body "* ]]; then
      cat "$FAKE_GH_STATE/body"
    elif [[ " $* " == *" --json isDraft "* ]]; then
      if [[ -f "$FAKE_GH_STATE/draft" ]]; then
        cat "$FAKE_GH_STATE/draft"
      else
        echo false
      fi
    fi
    ;;
  create | edit)
    notes_file=""
    previous=""
    for argument in "$@"; do
      if [[ "$previous" == "--notes-file" ]]; then
        notes_file="$argument"
        break
      fi
      previous="$argument"
    done
    [[ -n "$notes_file" ]]
    cp "$notes_file" "$FAKE_GH_STATE/body"
    touch "$FAKE_GH_STATE/exists"
    if [[ "$2" == "create" ]]; then
      echo false > "$FAKE_GH_STATE/draft"
    elif [[ " $* " == *" --draft=false "* ]]; then
      echo false > "$FAKE_GH_STATE/draft"
    fi
    ;;
  upload)
    ;;
  *)
    exit 2
    ;;
esac
FAKE_GH
chmod +x "$FAKE_GH_BIN/gh"

create_publish_fixture() {
  local version="$1"
  local run_id="$2"
  local source_sha="$3"
  local directory="$4"

  mkdir -p "$directory"
  printf 'dmg fixture for %s\n' "$version" \
    > "$directory/PowerLens-$version.dmg"
  printf 'zip fixture for %s\n' "$version" \
    > "$directory/PowerLens-$version.app.zip"
  (
    cd "$directory"
    shasum -a 256 \
      "PowerLens-$version.app.zip" \
      "PowerLens-$version.dmg" \
      > "PowerLens-$version-checksums.txt"
  )
  echo '<rss version="2.0"><channel /></rss>' > "$directory/appcast.xml"
  {
    echo "# PowerLens $version"
    echo
    echo "Fixture release notes."
    echo
    echo "<!-- powerlens-release-run-id: $run_id -->"
    echo "<!-- powerlens-release-sha: $source_sha -->"
  } > "$directory/release-notes.md"
}

manual_assets="$TEST_DIR/manual-assets"
create_publish_fixture 0.9.3 2001 "$manual_source" "$manual_assets"

invalid_checksum_state="$TEST_DIR/fake-gh-invalid-checksum-state"
invalid_checksum_assets="$TEST_DIR/invalid-checksum-assets"
mkdir -p "$invalid_checksum_state"
cp -R "$manual_assets" "$invalid_checksum_assets"
echo 'corruption' >> "$invalid_checksum_assets/PowerLens-0.9.3.app.zip"
if (
  cd "$WORK_REPOSITORY"
  PATH="$FAKE_GH_BIN:$PATH" \
    FAKE_GH_STATE="$invalid_checksum_state" \
    TAG=v0.9.3 \
    VERSION=0.9.3 \
    PRERELEASE=false \
    LATEST=true \
    SOURCE_SHA="$manual_source" \
    TAG_ORIGIN=reserved \
    RELEASE_RUN_ID=2001 \
    RELEASE_NOTES_PATH="$invalid_checksum_assets/release-notes.md" \
    RELEASE_ASSET_DIR="$invalid_checksum_assets" \
    "$PUBLISHER"
) >"$TEST_DIR/invalid-checksum.log" 2>&1; then
  echo "release workflow test: publisher accepted a corrupt release asset" >&2
  exit 1
fi
grep -Fq \
  "release publication: release asset checksum verification failed" \
  "$TEST_DIR/invalid-checksum.log"
[[ ! -f "$invalid_checksum_state/calls.log" ]]

invalid_appcast_state="$TEST_DIR/fake-gh-invalid-appcast-state"
invalid_appcast_assets="$TEST_DIR/invalid-appcast-assets"
mkdir -p "$invalid_appcast_state"
cp -R "$manual_assets" "$invalid_appcast_assets"
echo '<rss>' > "$invalid_appcast_assets/appcast.xml"
if (
  cd "$WORK_REPOSITORY"
  PATH="$FAKE_GH_BIN:$PATH" \
    FAKE_GH_STATE="$invalid_appcast_state" \
    TAG=v0.9.3 \
    VERSION=0.9.3 \
    PRERELEASE=false \
    LATEST=true \
    SOURCE_SHA="$manual_source" \
    TAG_ORIGIN=reserved \
    RELEASE_RUN_ID=2001 \
    RELEASE_NOTES_PATH="$invalid_appcast_assets/release-notes.md" \
    RELEASE_ASSET_DIR="$invalid_appcast_assets" \
    "$PUBLISHER"
) >"$TEST_DIR/invalid-appcast.log" 2>&1; then
  echo "release workflow test: publisher accepted an invalid appcast" >&2
  exit 1
fi
grep -Fq \
  "release publication: generated appcast is not valid XML" \
  "$TEST_DIR/invalid-appcast.log"
[[ ! -f "$invalid_appcast_state/calls.log" ]]

(
  cd "$WORK_REPOSITORY"
  PATH="$FAKE_GH_BIN:$PATH" \
    FAKE_GH_STATE="$FAKE_GH_STATE" \
    TAG=v0.9.3 \
    VERSION=0.9.3 \
    PRERELEASE=false \
    LATEST=true \
    SOURCE_SHA="$manual_source" \
    TAG_ORIGIN=reserved \
    RELEASE_RUN_ID=2001 \
    RELEASE_NOTES_PATH="$manual_assets/release-notes.md" \
    RELEASE_ASSET_DIR="$manual_assets" \
    "$PUBLISHER"
)
grep -Fq "release create" "$FAKE_GH_STATE/calls.log"
grep -Fq -- "--verify-tag" "$FAKE_GH_STATE/calls.log"

(
  cd "$WORK_REPOSITORY"
  PATH="$FAKE_GH_BIN:$PATH" \
    FAKE_GH_STATE="$FAKE_GH_STATE" \
    TAG=v0.9.3 \
    VERSION=0.9.3 \
    PRERELEASE=false \
    LATEST=true \
    SOURCE_SHA="$manual_source" \
    TAG_ORIGIN=reserved \
    RELEASE_RUN_ID=2001 \
    RELEASE_NOTES_PATH="$manual_assets/release-notes.md" \
    RELEASE_ASSET_DIR="$manual_assets" \
    "$PUBLISHER"
)
grep -Fq "release edit" "$FAKE_GH_STATE/calls.log"
grep -Fq "release upload" "$FAKE_GH_STATE/calls.log"

draft_state="$TEST_DIR/fake-gh-draft-state"
draft_assets="$TEST_DIR/draft-assets"
mkdir -p "$draft_state"
create_publish_fixture 0.10.0-alpha.1 1002 "$new_base_source" "$draft_assets"
cp "$draft_assets/release-notes.md" "$draft_state/body"
touch "$draft_state/exists"
echo true > "$draft_state/draft"

(
  cd "$WORK_REPOSITORY"
  PATH="$FAKE_GH_BIN:$PATH" \
    FAKE_GH_STATE="$draft_state" \
    TAG=v0.10.0-alpha.1 \
    VERSION=0.10.0-alpha.1 \
    PRERELEASE=true \
    LATEST=false \
    SOURCE_SHA="$new_base_source" \
    TAG_ORIGIN=reserved \
    RELEASE_RUN_ID=1002 \
    RELEASE_NOTES_PATH="$draft_assets/release-notes.md" \
    RELEASE_ASSET_DIR="$draft_assets" \
    "$PUBLISHER"
)
grep -Fq "release upload" "$draft_state/calls.log"
grep -Fq -- "--draft=false" "$draft_state/calls.log"
grep -Fqx false "$draft_state/draft"

event_state="$TEST_DIR/fake-gh-event-state"
event_assets="$TEST_DIR/event-assets"
mkdir -p "$event_state"
create_publish_fixture 0.9.4 3001 "$tag_source" "$event_assets"

(
  cd "$WORK_REPOSITORY"
  PATH="$FAKE_GH_BIN:$PATH" \
    FAKE_GH_STATE="$event_state" \
    TAG=v0.9.4 \
    VERSION=0.9.4 \
    PRERELEASE=false \
    LATEST=true \
    SOURCE_SHA="$tag_source" \
    TAG_ORIGIN=event \
    RELEASE_RUN_ID=3001 \
    RELEASE_NOTES_PATH="$event_assets/release-notes.md" \
    RELEASE_ASSET_DIR="$event_assets" \
    "$PUBLISHER"
)

different_event_assets="$TEST_DIR/different-event-assets"
create_publish_fixture 0.9.4 3002 "$tag_source" "$different_event_assets"
if (
  cd "$WORK_REPOSITORY"
  PATH="$FAKE_GH_BIN:$PATH" \
    FAKE_GH_STATE="$event_state" \
    TAG=v0.9.4 \
    VERSION=0.9.4 \
    PRERELEASE=false \
    LATEST=true \
    SOURCE_SHA="$tag_source" \
    TAG_ORIGIN=event \
    RELEASE_RUN_ID=3002 \
    RELEASE_NOTES_PATH="$different_event_assets/release-notes.md" \
    RELEASE_ASSET_DIR="$different_event_assets" \
    "$PUBLISHER"
); then
  echo "release workflow test: a different run clobbered an existing release" >&2
  exit 1
fi

echo "release workflow tests passed"
