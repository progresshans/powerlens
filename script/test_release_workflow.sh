#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW_PATH="$ROOT_DIR/.github/workflows/release.yml"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/powerlens-release-workflow-test.XXXXXX")"
RESOLVE_SCRIPT="$TEST_DIR/resolve-release-metadata.sh"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

ruby -ryaml - "$WORKFLOW_PATH" "$RESOLVE_SCRIPT" <<'RUBY'
workflow_path, resolve_script_path = ARGV
workflow = YAML.safe_load(File.read(workflow_path), aliases: false)
triggers = workflow["on"] || workflow[true]
abort "release workflow: missing on trigger" unless triggers.is_a?(Hash)

push = triggers["push"]
abort "release workflow: missing push trigger" unless push.is_a?(Hash)

branches = Array(push["branches"])
unless branches == ["develop"]
  abort "release workflow: expected automatic releases only from develop"
end

tags = Array(push["tags"])
unless tags == ["v*"]
  abort 'release workflow: expected explicit v* tag releases'
end

steps = workflow.dig("jobs", "publish", "steps")
abort "release workflow: missing publish steps" unless steps.is_a?(Array)

metadata_step = steps.find { |step| step["name"] == "Resolve release metadata" }
abort "release workflow: missing metadata resolution step" unless metadata_step

run_script = metadata_step["run"]
abort "release workflow: metadata resolution step has no script" unless run_script

File.write(resolve_script_path, run_script)
RUBY

run_case() {
  local name="$1"
  local ref_type="$2"
  local ref_name="$3"
  local dispatch_version="$4"
  local dispatch_channel="$5"
  local alpha_base_version="$6"
  local working_directory="$7"
  local output_path="$TEST_DIR/$name.output"

  (
    cd "$working_directory"
    GITHUB_REF_TYPE="$ref_type" \
      GITHUB_REF_NAME="$ref_name" \
      GITHUB_RUN_NUMBER="42" \
      GITHUB_REPOSITORY="progresshans/powerlens" \
      GITHUB_OUTPUT="$output_path" \
      DISPATCH_VERSION="$dispatch_version" \
      DISPATCH_CHANNEL="$dispatch_channel" \
      ALPHA_BASE_VERSION="$alpha_base_version" \
      bash "$RESOLVE_SCRIPT"
  )
}

assert_output() {
  local output_path="$1"
  shift

  for expected in "$@"; do
    grep -Fqx "$expected" "$output_path"
  done
}

FALLBACK_REPOSITORY="$TEST_DIR/fallback-repository"
git init -q "$FALLBACK_REPOSITORY"
git -C "$FALLBACK_REPOSITORY" \
  -c user.name="PowerLens Tests" \
  -c user.email="tests@powerlens.invalid" \
  commit --allow-empty -q -m "fixture"
git -C "$FALLBACK_REPOSITORY" tag v0.9.2
git -C "$FALLBACK_REPOSITORY" tag v0.9.3-alpha.99

run_case develop branch develop "" "" "" "$FALLBACK_REPOSITORY"
assert_output \
  "$TEST_DIR/develop.output" \
  "version=0.9.3-alpha.42" \
  "tag=v0.9.3-alpha.42" \
  "channel=alpha" \
  "appcast_path=docs/appcast-alpha.xml" \
  "prerelease=true" \
  "latest=false"

run_case stable-tag tag v0.9.3 "" "" "" "$ROOT_DIR"
assert_output \
  "$TEST_DIR/stable-tag.output" \
  "version=0.9.3" \
  "tag=v0.9.3" \
  "channel=stable" \
  "appcast_path=docs/appcast.xml" \
  "prerelease=false" \
  "latest=true"

run_case manual-alpha branch develop 0.9.3-alpha.8 alpha "" "$ROOT_DIR"
assert_output \
  "$TEST_DIR/manual-alpha.output" \
  "version=0.9.3-alpha.8" \
  "tag=v0.9.3-alpha.8" \
  "channel=alpha" \
  "appcast_path=docs/appcast-alpha.xml" \
  "prerelease=true" \
  "latest=false"

echo "release workflow tests passed"
