#!/usr/bin/env bash
set -euo pipefail

STABLE_APPCAST="${1:?usage: validate_appcast_progression.sh STABLE_APPCAST ALPHA_APPCAST GENERATED_APPCAST NEW_VERSION CHANNEL}"
ALPHA_APPCAST="${2:?usage: validate_appcast_progression.sh STABLE_APPCAST ALPHA_APPCAST GENERATED_APPCAST NEW_VERSION CHANNEL}"
GENERATED_APPCAST="${3:?usage: validate_appcast_progression.sh STABLE_APPCAST ALPHA_APPCAST GENERATED_APPCAST NEW_VERSION CHANNEL}"
NEW_VERSION="${4:?usage: validate_appcast_progression.sh STABLE_APPCAST ALPHA_APPCAST GENERATED_APPCAST NEW_VERSION CHANNEL}"
CHANNEL="${5:?usage: validate_appcast_progression.sh STABLE_APPCAST ALPHA_APPCAST GENERATED_APPCAST NEW_VERSION CHANNEL}"

python3 - \
  "$STABLE_APPCAST" \
  "$ALPHA_APPCAST" \
  "$GENERATED_APPCAST" \
  "$NEW_VERSION" \
  "$CHANNEL" <<'PY'
from pathlib import Path
import re
import sys
from typing import Optional
import xml.etree.ElementTree as ET

(
    stable_appcast_path,
    alpha_appcast_path,
    generated_appcast_path,
    new_version,
    channel,
) = sys.argv[1:]
stable_pattern = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
alpha_pattern = re.compile(r"^(\d+)\.(\d+)\.(\d+)-alpha\.(\d+)$")
build_pattern = re.compile(r"^\d+(?:\.\d+){0,2}$")
namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"

if channel not in ("stable", "alpha"):
    raise SystemExit(f"appcast progression: unsupported channel: {channel}")


def parse_version(value: str, expected_channel: str) -> tuple[int, ...]:
    pattern = stable_pattern if expected_channel == "stable" else alpha_pattern
    match = pattern.fullmatch(value)
    if match is None:
        raise SystemExit(
            f"appcast progression: {value!r} is not a valid "
            f"{expected_channel} version"
        )
    return tuple(int(part) for part in match.groups())


def parse_build(value: str) -> tuple[int, int, int]:
    if build_pattern.fullmatch(value) is None:
        raise SystemExit(
            f"appcast progression: {value!r} is not a valid Sparkle build version"
        )
    parts = [int(part) for part in value.split(".")]
    return tuple(parts + [0] * (3 - len(parts)))


def item_value(item: ET.Element, name: str) -> Optional[str]:
    key = f"{{{namespace}}}{name}"
    enclosure = item.find("enclosure")
    if enclosure is not None:
        attribute = enclosure.attrib.get(key)
        if attribute and attribute.strip():
            return attribute.strip()

    element = item.find(key)
    if element is not None and element.text and element.text.strip():
        return element.text.strip()
    return None


def read_releases(path: str) -> list[tuple[str, str]]:
    tree = ET.parse(Path(path))
    releases = []
    for item in tree.findall(".//item"):
        version = item_value(item, "shortVersionString")
        build = item_value(item, "version")
        if version is None or build is None:
            raise SystemExit(
                "appcast progression: every release item must contain "
                "sparkle:shortVersionString and sparkle:version"
            )
        parse_build(build)
        releases.append((version, build))
    return releases


new_key = parse_version(new_version, channel)
generated_releases = read_releases(generated_appcast_path)
generated_matches = [
    (version, build)
    for version, build in generated_releases
    if version == new_version
]
if len(generated_matches) != 1:
    raise SystemExit(
        "appcast progression: generated appcast must contain exactly one "
        f"release for {new_version}, found {len(generated_matches)}"
    )
_, new_build = generated_matches[0]
new_build_key = parse_build(new_build)

stable_releases = read_releases(stable_appcast_path)
alpha_releases = read_releases(alpha_appcast_path)
for version, _ in stable_releases:
    parse_version(version, "stable")
for version, _ in alpha_releases:
    parse_version(version, "alpha")

target_releases = stable_releases if channel == "stable" else alpha_releases
all_releases = stable_releases + alpha_releases
target_match_exists = any(
    version == new_version and parse_build(build) == new_build_key
    for version, build in target_releases
)

current_key = None
current_version = None
target_build_key = None
if target_releases:
    published_versions = [
        (parse_version(version, channel), version)
        for version, _ in target_releases
    ]
    current_key, current_version = max(published_versions)
    if new_key < current_key:
        raise SystemExit(
            "appcast progression: refusing to replace "
            f"{channel} {current_version} with older {new_version}"
        )
    target_build_key = max(
        parse_build(build)
        for _, build in target_releases
    )

exact_target_resume = (
    target_match_exists
    and new_key == current_key
    and new_build_key == target_build_key
)

current_build_key = None
current_build = None
published_builds = [
    (parse_build(build), build)
    for _, build in all_releases
]
if published_builds:
    current_build_key, current_build = max(published_builds)
    if not exact_target_resume and new_build_key < current_build_key:
        raise SystemExit(
            "appcast progression: refusing to replace the highest published "
            f"Sparkle build {current_build} with older build {new_build}"
        )
    if not exact_target_resume and new_build_key == current_build_key:
        raise SystemExit(
            "appcast progression: refusing to publish a new release without "
            f"increasing the cross-channel Sparkle build {new_build}"
        )

if exact_target_resume:
    print(
        f"appcast progression: resuming {channel} {new_version} "
        f"(build {new_build})"
    )
elif current_key is None:
    if current_build is None:
        print(
            f"appcast progression: neither feed has a published version; "
            f"accepting {channel} {new_version} (build {new_build})"
        )
    else:
        print(
            f"appcast progression: creating the first {channel} release "
            f"{new_version} and advancing Sparkle build "
            f"{current_build} -> {new_build}"
        )
elif new_key == current_key:
    print(
        f"appcast progression: advancing Sparkle build "
        f"{current_build} -> {new_build} for {channel} {new_version}"
    )
else:
    print(
        f"appcast progression: advancing {channel} "
        f"{current_version} -> {new_version} and Sparkle build "
        f"{current_build} -> {new_build}"
    )
PY
