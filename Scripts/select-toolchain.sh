#!/bin/bash
# Select a Swift toolchain that can read this package's manifest, and prove it.
#
# `Package.swift` declares `swift-tools-version: 6.0`.  A machine whose selected
# developer directory predates that fails at the very first `swift build` with
#
#     error: 'downright': package 'downright' is using Swift tools version
#            6.0.0 but the installed version is 5.10.0
#
# which says nothing about *which* Xcode is selected or which ones are present.
# GitHub's macOS images ship several Xcodes and the default selection is not
# guaranteed to be the newest, so relying on it silently couples every CI run to
# an image detail nobody controls.
#
# This script picks the newest installed Xcode, exports it for the rest of the
# job through `DEVELOPER_DIR` (which outranks `xcode-select` and needs no sudo),
# and then *asserts* the resulting toolchain satisfies the manifest.  A future
# image regression therefore fails here, naming the versions it found, instead
# of surfacing as the cryptic error above three steps later.
#
# Sourcing is not required: when running under GitHub Actions the choice is
# written to $GITHUB_ENV so every later step inherits it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The tools version the manifest demands, read from the manifest itself so this
# script cannot drift away from it.
REQUIRED="$(sed -n 's|^// *swift-tools-version: *\([0-9][0-9.]*\).*|\1|p' "$ROOT/Package.swift" | head -1)"
[ -n "$REQUIRED" ] || { echo "select-toolchain: cannot read swift-tools-version from Package.swift" >&2; exit 1; }
REQUIRED_MAJOR="${REQUIRED%%.*}"
REQUIRED_MINOR="$(echo "$REQUIRED" | cut -s -d. -f2)"
REQUIRED_MINOR="${REQUIRED_MINOR:-0}"

# The already-selected developer directory is tried first, so a machine that is
# fine as it stands is left exactly as it is.  Only when the selection cannot
# read the manifest — a Command Line Tools directory, or an Xcode too old — does
# this reach for another, and then it takes the newest that works.
#
# That ordering matters on CI: the runner image's default Xcode is the one its
# other tooling is matched to, and silently upgrading every build to whatever
# newest Xcode happens to be installed would make the toolchain drift with the
# image instead of with a deliberate change here.
CANDIDATES=()
CURRENT="$(xcode-select -p 2>/dev/null || true)"
case "$CURRENT" in
    */Contents/Developer) CANDIDATES+=("${CURRENT%/Contents/Developer}") ;;
esac

# Remaining candidates, newest first.  `sort -V` orders 9.0 < 16.4 < 26.0
# correctly, which a lexical sort does not.
while IFS= read -r app; do
    [ -d "$app/Contents/Developer" ] || continue
    [ "${CANDIDATES[0]:-}" = "$app" ] && continue
    CANDIDATES+=("$app")
done < <(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V -r)

swift_version_of() {
    DEVELOPER_DIR="$1/Contents/Developer" swift --version 2>/dev/null \
        | sed -n 's|.*Swift version \([0-9][0-9.]*\).*|\1|p' | head -1
}

satisfies() {
    local major minor
    major="${1%%.*}"
    minor="$(echo "$1" | cut -s -d. -f2)"
    minor="${minor:-0}"
    [ "$major" -gt "$REQUIRED_MAJOR" ] && return 0
    [ "$major" -eq "$REQUIRED_MAJOR" ] && [ "$minor" -ge "$REQUIRED_MINOR" ] && return 0
    return 1
}

echo "==> Toolchain (manifest needs Swift >= $REQUIRED)"

FOUND=""
REPORT=""
# macOS ships bash 3.2, where an empty array expands to an *unbound variable*
# error under `set -u` rather than to nothing.  A machine with no Xcode at all
# is precisely the case this script exists to report clearly, so it must not
# die here with a shell diagnostic instead.
for app in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
    version="$(swift_version_of "$app")"
    [ -n "$version" ] || continue
    REPORT="$REPORT    $app -> Swift $version"$'\n'
    if [ -z "$FOUND" ] && satisfies "$version"; then
        FOUND="$app"
        SELECTED_VERSION="$version"
    fi
done

if [ -z "$FOUND" ]; then
    echo "    FAILED: no installed Xcode provides Swift >= $REQUIRED" >&2
    if [ -n "$REPORT" ]; then
        echo "    Installed toolchains:" >&2
        printf '%s' "$REPORT" >&2
    else
        echo "    No /Applications/Xcode*.app with a usable swift was found." >&2
    fi
    exit 1
fi

DEVELOPER_DIR="$FOUND/Contents/Developer"
export DEVELOPER_DIR
echo "    $FOUND (Swift $SELECTED_VERSION)"

# Hand the choice to every later step in the job.
if [ -n "${GITHUB_ENV:-}" ]; then
    echo "DEVELOPER_DIR=$DEVELOPER_DIR" >> "$GITHUB_ENV"
fi

# Final proof: the manifest itself must parse under the selected toolchain.
# `swift package dump-package` is the cheapest operation that reads it.
if ! (cd "$ROOT" && swift package dump-package > /dev/null 2>&1); then
    echo "    FAILED: the manifest does not parse under Swift $SELECTED_VERSION" >&2
    (cd "$ROOT" && swift package dump-package 2>&1 | head -5) >&2
    exit 1
fi
echo "    manifest parses"
