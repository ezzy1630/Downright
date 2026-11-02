#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
EXISTING="$(git config --get core.hooksPath || true)"
if [ -n "$EXISTING" ] && [ "$EXISTING" != .githooks ] && [ "$EXISTING" != "$ROOT/.githooks" ]; then
    echo "Existing hook path preserved: $EXISTING" >&2
    exit 1
fi
DEFAULT_HOOK="$(git rev-parse --git-path hooks/pre-push)"
if [ -z "$EXISTING" ] && [ -e "$DEFAULT_HOOK" ]; then
    echo "Existing pre-push hook preserved: $DEFAULT_HOOK" >&2
    exit 1
fi
Scripts/install-actionlint.sh
git config --local core.hooksPath .githooks
echo "Installed exact-commit pre-push checks"
