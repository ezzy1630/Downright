#!/usr/bin/env python3
"""Print a version's curated changelog section as its release notes.

These notes are the GitHub Release text and the update notes the app shows
before someone installs an update, so a version without its own changelog
section is an error rather than a fallback to commit subjects.
"""
import argparse
from pathlib import Path
import re
import sys


def version_notes(changelog, version):
    heading = re.compile(r"##[ \t]+\[" + re.escape(version) + r"\](?:[ \t]+-[ \t]+.+)?[ \t]*")
    sections = []
    current = None
    fence = None
    for line in changelog.splitlines(keepends=True):
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line.rstrip("\r\n"))
        if fence is not None:
            if current is not None:
                current.append(line)
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= fence[1] and not marker[2].strip():
                fence = None
            continue
        if marker:
            fence = (marker[1][0], len(marker[1]))
        elif re.match(r"^##[ \t]+", line):
            if current is not None:
                sections.append("".join(current).strip())
            current = [] if heading.fullmatch(line.rstrip("\r\n")) else None
            continue
        if current is not None:
            current.append(line)
    if current is not None:
        sections.append("".join(current).strip())
    if len(sections) > 1:
        raise ValueError(f"duplicate changelog sections for {version}")
    if sections:
        visible = re.sub(r"<!--.*?(?:-->|$)", "", sections[0], flags=re.S).strip()
        if not visible:
            raise ValueError(f"empty changelog section for {version}")
    return sections[0] if sections else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("build")
    parser.add_argument("repository", help="GitHub owner/name")
    parser.add_argument("--changelog", type=Path, default=Path(__file__).resolve().parents[1] / "CHANGELOG.md")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version):
        parser.error("version must be X.Y.Z")
    if not re.fullmatch(r"[1-9][0-9]*", args.build):
        parser.error("build must be a positive integer")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        parser.error("repository must be owner/name")
    try:
        notes = version_notes(args.changelog.read_text(encoding="utf-8"), args.version)
        if notes is None:
            raise ValueError(
                f"{args.changelog.name} has no ## [{args.version}] section; move the "
                "[Unreleased] notes into it before releasing"
            )
        print(f"# Downright {args.version} (build {args.build})\n\n{notes}\n")
        print(f"_Full history: https://github.com/{args.repository}/releases_")
    except (OSError, UnicodeError, ValueError) as error:
        print(f"release-notes: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
