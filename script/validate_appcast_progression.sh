#!/usr/bin/env bash
set -euo pipefail

CURRENT_APPCAST="${1:?usage: validate_appcast_progression.sh CURRENT_APPCAST GENERATED_APPCAST NEW_VERSION CHANNEL}"
GENERATED_APPCAST="${2:?usage: validate_appcast_progression.sh CURRENT_APPCAST GENERATED_APPCAST NEW_VERSION CHANNEL}"
NEW_VERSION="${3:?usage: validate_appcast_progression.sh CURRENT_APPCAST GENERATED_APPCAST NEW_VERSION CHANNEL}"
CHANNEL="${4:?usage: validate_appcast_progression.sh CURRENT_APPCAST GENERATED_APPCAST NEW_VERSION CHANNEL}"

python3 - "$CURRENT_APPCAST" "$GENERATED_APPCAST" "$NEW_VERSION" "$CHANNEL" <<'PY'
from pathlib import Path
import re
import sys
from typing import Optional
import xml.etree.ElementTree as ET

current_appcast_path, generated_appcast_path, new_version, channel = sys.argv[1:]
stable_pattern = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
alpha_pattern = re.compile(r"^(\d+)\.(\d+)\.(\d+)-alpha\.(\d+)$")
build_pattern = re.compile(r"^\d+(?:\.\d+){0,2}$")
namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"

if channel == "stable":
    pattern = stable_pattern
elif channel == "alpha":
    pattern = alpha_pattern
else:
    raise SystemExit(f"appcast progression: unsupported channel: {channel}")


def parse_version(value: str) -> tuple[int, ...]:
    match = pattern.fullmatch(value)
    if match is None:
        raise SystemExit(
            f"appcast progression: {value!r} is not a valid {channel} version"
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


new_key = parse_version(new_version)
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

published_releases = read_releases(current_appcast_path)
if not published_releases:
    print(
        f"appcast progression: {channel} feed has no published version; "
        f"accepting {new_version} (build {new_build})"
    )
    raise SystemExit(0)

published_versions = [
    (parse_version(version), version)
    for version, _ in published_releases
]
published_builds = [
    (parse_build(build), build)
    for _, build in published_releases
]
current_key, current_version = max(published_versions)
current_build_key, current_build = max(published_builds)

if new_key < current_key:
    raise SystemExit(
        "appcast progression: refusing to replace "
        f"{channel} {current_version} with older {new_version}"
    )

if new_build_key < current_build_key:
    raise SystemExit(
        "appcast progression: refusing to replace Sparkle build "
        f"{current_build} with older build {new_build}"
    )

if new_key > current_key and new_build_key == current_build_key:
    raise SystemExit(
        "appcast progression: refusing to advance "
        f"{channel} {current_version} -> {new_version} without increasing "
        f"Sparkle build {new_build}"
    )

if new_key == current_key and new_build_key == current_build_key:
    print(
        f"appcast progression: resuming {channel} {new_version} "
        f"(build {new_build})"
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
