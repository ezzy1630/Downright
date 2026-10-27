#!/usr/bin/env python3
"""Use a version's curated changelog, with Git history for unlisted versions."""
import argparse
from pathlib import Path
import re
import subprocess
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
    if sections and not sections[0]:
        raise ValueError(f"empty changelog section for {version}")
    return sections[0] if sections else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("build")
    parser.add_argument("repository", help="GitHub owner/name")
    parser.add_argument("--changelog", type=Path, default=Path(__file__).resolve().parents[1] / "CHANGELOG.md")
    parser.add_argument("--previous-tag", default="")
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
            command = ["git", "log", "--oneline", "--no-merges"]
            command += ["--end-of-options", args.previous_tag + "..HEAD"] if args.previous_tag else ["-30", "HEAD"]
            commits = subprocess.run(command + ["--"], check=True, capture_output=True, text=True).stdout
            notes = "## What's new\n\n" + "\n".join("- " + line for line in commits.splitlines())
        print(f"# Downright {args.version} (build {args.build})\n\n{notes}\n")
        print(f"_Full history: https://github.com/{args.repository}/releases_")
    except (OSError, UnicodeError, ValueError, subprocess.CalledProcessError) as error:
        print(f"release-notes: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
