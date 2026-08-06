#!/bin/bash
# One canonical release version (Config/version.env), every consumer verified.
#
# Verifies (or with --fix, rewrites) the places a version number is hard-coded:
#   * project.yml        — MARKETING_VERSION
#   * MarkdownCLI.swift  — the `down --version` string
#   * bundle scripts     — read this file themselves after this change
#   * Info.plist templates — use $(MARKETING_VERSION) / $(CURRENT_PROJECT_VERSION)
#
# Run by Scripts/check.sh so a version that drifts out of sync fails CI, and by
# the release workflow as an explicit gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="${1:-verify}"

# shellcheck disable=SC1091
source Config/version.env

fail() {
    echo "version consistency failure: $1" >&2
    exit 1
}

# --- project.yml -------------------------------------------------------------
# MARKETING_VERSION appears once per target (app + two extensions); all of them
# must agree with the canonical value.
PROJECT_VERSIONS="$(grep -E '^[[:space:]]+MARKETING_VERSION:' project.yml | awk '{print $2}' | sort -u)"
if [ "$PROJECT_VERSIONS" != "$MARKETING_VERSION" ]; then
    if [ "$MODE" = "fix" ]; then
        sed -i '' "s/^\([[:space:]]*MARKETING_VERSION:\) .*/\1 $MARKETING_VERSION/" project.yml
        echo "fixed project.yml MARKETING_VERSION -> $MARKETING_VERSION"
    else
        fail "project.yml says '$PROJECT_VERSIONS', Config/version.env says '$MARKETING_VERSION'. Run: Scripts/sync-versions.sh fix"
    fi
fi

# --- MarkdownCLI (down --version) -------------------------------------------
CLI_VERSION="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' Sources/drdownright/MarkdownCLI.swift)"
if [ "$CLI_VERSION" != "$MARKETING_VERSION" ]; then
    if [ "$MODE" = "fix" ]; then
        sed -i '' "s/\(static let version = \"\)[^\"]*\(\"\)/\1$MARKETING_VERSION\2/" Sources/drdownright/MarkdownCLI.swift
        echo "fixed MarkdownCLI.swift version -> $MARKETING_VERSION"
    else
        fail "MarkdownCLI.version says '$CLI_VERSION', Config/version.env says '$MARKETING_VERSION'. Run: Scripts/sync-versions.sh fix"
    fi
fi

# --- Info.plist templates ----------------------------------------------------
# The templates use $(MARKETING_VERSION)/$(CURRENT_PROJECT_VERSION) build
# settings; verify they really do.
for plist in Config/Downright-Info.plist Config/DownrightQL-Info.plist Config/DownrightThumb-Info.plist; do
    grep -q '\$(MARKETING_VERSION)' "$plist" || fail "$plist does not use \$(MARKETING_VERSION)"
    grep -q '\$(CURRENT_PROJECT_VERSION)' "$plist" || fail "$plist does not use \$(CURRENT_PROJECT_VERSION)"
done

echo "versions consistent: $MARKETING_VERSION (build $CURRENT_PROJECT_VERSION)"
