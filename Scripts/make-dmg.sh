#!/bin/bash
# Package a built Downright.app into a drag-install DMG.
#
# Usage:
#   Scripts/make-dmg.sh [path/to/Downright.app]
#
# With no argument the script looks for the app produced by the most recent
# build pipeline:
#   * $APP env var, if set
#   * .build-xcode/Build/Products/Release/Downright.app   (bundle-xcode-app.sh)
#   * .build-main/bundle/Downright.app                    (bundle-app.sh)
#
# Env:
#   OUT_DIR   where the DMG lands (default: $ROOT/dist)
#   VOLNAME   volume name override (default: "Downright $MARKETING_VERSION")
#
# Produces OUT_DIR/Downright-<MARKETING_VERSION>.dmg containing the app and an
# /Applications symlink, so double-click → drag to Applications.  Run this on
# the signed+notarized app (see RELEASE.md); the DMG is a container, so the
# ticket inside the app is what Gatekeeper checks, but notarizing the DMG
# itself too is cheap and covers users who run straight from the image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source Config/version.env

APP="${APP:-${1:-}}"
if [ -z "$APP" ] && [ -d ".build-xcode/Build/Products/Release/Downright.app" ]; then
    APP=".build-xcode/Build/Products/Release/Downright.app"
elif [ -z "$APP" ] && [ -d ".build-main/bundle/Downright.app" ]; then
    APP=".build-main/bundle/Downright.app"
fi
[ -n "$APP" ] || {
    echo "usage: Scripts/make-dmg.sh [path/to/Downright.app]" >&2
    echo "(no app found in .build-xcode or .build-main; pass one explicitly)" >&2
    exit 1
}
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
[ -d "$APP" ] || { echo "not an app bundle: $APP" >&2; exit 1; }

OUT_DIR="${OUT_DIR:-$ROOT/dist}"
VOLNAME="${VOLNAME:-Downright $MARKETING_VERSION}"
DMG="$OUT_DIR/Downright-$MARKETING_VERSION.dmg"

echo "==> Packaging $APP"
echo "    -> $DMG"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$OUT_DIR"
# UDZO (zlib) is the safe default: readable by every macOS since 10.6.
# --volname must match the final volume name; macOS renames the image to the
# volname on attach, so a mismatch looks like a bug.
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

echo "==> Verifying image"
hdiutil verify "$DMG" >/dev/null

echo
echo "Built $DMG"
echo
echo "Next (release path):"
echo "  xcrun notarytool submit \"$DMG\" --keychain-profile \"AC_PASSWORD\" --wait"
echo "  xcrun stapler staple \"$DMG\""
echo "  (or run Scripts/sign-and-notarize.sh with MAKE_DMG=1, which does both)"
