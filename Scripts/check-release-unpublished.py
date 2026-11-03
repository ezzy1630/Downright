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
            ["gh", "api", "--include", f"repos/{repository}/releases/tags/{tag}"],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        print("release: could not check the existing release", file=sys.stderr)
        return 1
    statuses = re.findall(r"^HTTP/\S+ ([0-9]{3})\b", result.stdout, re.MULTILINE)
    status = statuses[-1] if statuses else None
    if status == "404" and result.returncode == 1:
        return 0
    if status == "200" and result.returncode == 0:
        print(f"release: {tag} already exists; do not rebuild or overwrite its app artifacts. "
              "Recover deployment from the existing artifacts or release a new commit.",
              file=sys.stderr)
    else:
        print(f"release: existing-release check failed (HTTP {status or 'unavailable'})",
              file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
