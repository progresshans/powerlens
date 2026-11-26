#!/usr/bin/env python3
"""Prepare release notes for the Sparkle update window.

GitHub turns `#123` and `@name` in a release body into links by itself. Sparkle
shows the Markdown in the appcast as written, so this script writes those links
out. It also drops the document title, because the update window already names
the app and the version.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

USAGE = "usage: generate_update_notes.py RELEASE_NOTES_PATH OUTPUT_PATH REPOSITORY"

REPOSITORY = re.compile(r"[A-Za-z0-9](?:-?[A-Za-z0-9])*/[A-Za-z0-9._-]+")
FENCE = re.compile(r"\s{0,3}(`{3,}|~{3,})")
TITLE = re.compile(r"# \S")

# Text that already means something else and must stay as written: inline code,
# Markdown links and images, HTML tags and comments, and bare URLs.
PROTECTED = re.compile(
    r"(?P<ticks>`+).+?(?P=ticks)"
    r"|!?\[[^\]\n]*\]\([^)\n]*\)"
    r"|<[^>\n]+>"
    r"|https?://[^\s<>]+"
)

# `#123`, unless it is part of a longer word, an HTML entity or a path.
NUMBER = re.compile(r"(?<![\w&#/])#(\d+)\b")

# `@name` after whitespace, an opening parenthesis or the start of the line. The
# name follows GitHub's rules: letters, digits and single hyphens, at most 39
# characters. An email address, `@org/team` and `@name.ext` are left alone.
MENTION = re.compile(
    r"(?<![^\s(])@([A-Za-z0-9](?:-?[A-Za-z0-9]){0,38})(?![\w/-])(?!\.\w)"
)


def link_line(line: str, repository: str) -> str:
    protected = [match.span() for match in PROTECTED.finditer(line)]

    def is_protected(start: int, end: int) -> bool:
        return any(start < span_end and span_start < end for span_start, span_end in protected)

    replacements: list[tuple[int, int, str]] = []
    for match in NUMBER.finditer(line):
        if not is_protected(*match.span()):
            number = match.group(1)
            target = f"https://github.com/{repository}/pull/{number}"
            replacements.append((*match.span(), f"[#{number}]({target})"))
    for match in MENTION.finditer(line):
        if not is_protected(*match.span()):
            name = match.group(1)
            replacements.append((*match.span(), f"[@{name}](https://github.com/{name})"))

    for start, end, text in sorted(replacements, reverse=True):
        line = line[:start] + text + line[end:]
    return line


def update_notes(release_notes: str, repository: str) -> str:
    if not REPOSITORY.fullmatch(repository):
        raise ValueError(f"update notes: invalid repository: {repository}")

    lines = release_notes.strip().split("\n")
    if lines and TITLE.match(lines[0]):
        lines = lines[1:]
        while lines and not lines[0].strip():
            lines = lines[1:]

    output: list[str] = []
    fence = ""
    for line in lines:
        marker = FENCE.match(line)
        if fence:
            output.append(line)
            if marker and marker.group(1).startswith(fence) and not line.strip().strip("`~"):
                fence = ""
            continue
        if marker:
            fence = marker.group(1)
            output.append(line)
            continue
        output.append(link_line(line, repository))

    text = "\n".join(output).strip()
    if not text:
        raise ValueError("update notes: the release notes have no content below their title")
    return text + "\n"


def main(arguments: list[str]) -> int:
    if len(arguments) != 3:
        print(USAGE, file=sys.stderr)
        return 2

    release_notes_path, output_path, repository = arguments
    try:
        notes = update_notes(Path(release_notes_path).read_text(encoding="utf-8"), repository)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1

    destination = Path(output_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(notes, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
