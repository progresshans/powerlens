#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?usage: generate_release_notes.sh VERSION OUTPUT_PATH [CHANGELOG_PATH]}"
OUTPUT_PATH="${2:?usage: generate_release_notes.sh VERSION OUTPUT_PATH [CHANGELOG_PATH]}"
CHANGELOG_PATH="${3:-$ROOT_DIR/CHANGELOG.md}"

python3 - "$VERSION" "$CHANGELOG_PATH" "$OUTPUT_PATH" <<'PY'
from pathlib import Path
import re
import sys

version, changelog_path, output_path = sys.argv[1:]
text = Path(changelog_path).read_text(encoding="utf-8")

base_version = re.sub(r"-alpha\.\d+$", "", version)
candidates = [version]
if base_version != version:
    candidates.append(base_version)
    candidates.append("Unreleased")

sections: dict[str, str] = {}
matches = list(
    re.finditer(
        r"^## \[([^\]]+)\](?:\s+-\s+.*)?\s*$",
        text,
        flags=re.MULTILINE,
    )
)
for index, match in enumerate(matches):
    start = match.end()
    end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
    sections[match.group(1)] = text[start:end].strip()

selected = next(
    (sections[candidate] for candidate in candidates if sections.get(candidate)),
    None,
)
if not selected:
    choices = ", ".join(candidates)
    raise SystemExit(
        f"release notes: CHANGELOG.md has no non-empty section for {choices}"
    )

# CHANGELOG entries live below a level-two version heading. The generated
# release document replaces that heading with its own level-one title, so lift
# the entry's level-three sections to level two as well.
selected = re.sub(r"^### ", "## ", selected, flags=re.MULTILINE)

parts = [f"# PowerLens {version}"]
if "-alpha." in version:
    parts.append(
        "> Alpha preview: behavior and data presentation may still change "
        "before the stable release."
    )
parts.append(selected)

destination = Path(output_path)
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text("\n\n".join(parts) + "\n", encoding="utf-8")
PY
