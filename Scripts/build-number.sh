#!/bin/bash
# Print a stable build number for committed trees and a unique one for local builds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

COMMIT_COUNT="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
if git diff --quiet --ignore-submodules -- \
    && git diff --cached --quiet --ignore-submodules -- \
    && [ -z "$(git ls-files --others --exclude-standard)" ]; then
    echo "$COMMIT_COUNT"
    exit 0
fi

# CFBundleVersion accepts up to three numeric components. Encode the current
# epoch in base 100 so every dirty build gets fresh Launch Services metadata.
EPOCH="$(date -u +%s)"
MAJOR="$((EPOCH / 10000 % 10000))"
MINOR="$((EPOCH / 100 % 100))"
PATCH="$((EPOCH % 100))"
printf '%d.%02d.%02d\n' "$MAJOR" "$MINOR" "$PATCH"
