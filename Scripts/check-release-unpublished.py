#!/usr/bin/env python3
"""Reject an existing release without treating API failures as permission to publish."""
import os
import re
import subprocess
import sys


def main():
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    revision = os.environ.get("GITHUB_SHA", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) \
            or not re.fullmatch(r"[0-9a-f]{40}", revision):
        print("release: invalid repository or commit identity", file=sys.stderr)
        return 1
    tag = "auto-" + revision
    try:
        result = subprocess.run(
            # The by-tag endpoint omits drafts. Include them so an interrupted
            # upload cannot silently combine old assets with a rebuilt app.
            ["gh", "api", "--paginate", f"repos/{repository}/releases?per_page=100",
             "--jq", f'.[] | select(.tag_name == "{tag}") | .id'],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"release: could not check the existing release: {error}", file=sys.stderr)
        return 1
    if result.returncode != 0:
        print("release: existing-release lookup failed", file=sys.stderr)
        if result.stderr.strip():
            print(result.stderr.strip(), file=sys.stderr)
        return 1
    if result.stdout.strip():
        print(f"release: {tag} already exists; do not rebuild or overwrite its app artifacts. "
              "Recover from the retained publication inputs or release a new commit.",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
