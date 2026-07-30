#!/usr/bin/env bash
set -euo pipefail

CURRENT_APPCAST="${1:?usage: validate_appcast_progression.sh CURRENT_APPCAST NEW_VERSION CHANNEL}"
NEW_VERSION="${2:?usage: validate_appcast_progression.sh CURRENT_APPCAST NEW_VERSION CHANNEL}"
CHANNEL="${3:?usage: validate_appcast_progression.sh CURRENT_APPCAST NEW_VERSION CHANNEL}"

python3 - "$CURRENT_APPCAST" "$NEW_VERSION" "$CHANNEL" <<'PY'
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

appcast_path, new_version, channel = sys.argv[1:]
stable_pattern = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
alpha_pattern = re.compile(r"^(\d+)\.(\d+)\.(\d+)-alpha\.(\d+)$")

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


new_key = parse_version(new_version)
tree = ET.parse(Path(appcast_path))
namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
published_versions = [
    element.text.strip()
    for element in tree.findall(f".//{{{namespace}}}shortVersionString")
    if element.text and element.text.strip()
]

if not published_versions:
    print(f"appcast progression: {channel} feed has no published version")
    raise SystemExit(0)

published = [(parse_version(version), version) for version in published_versions]
current_key, current_version = max(published)
if new_key < current_key:
    raise SystemExit(
        "appcast progression: refusing to replace "
        f"{channel} {current_version} with older {new_version}"
    )
if new_key == current_key:
    print(f"appcast progression: resuming {channel} {new_version}")
else:
    print(
        f"appcast progression: advancing {channel} "
        f"{current_version} -> {new_version}"
    )
PY
