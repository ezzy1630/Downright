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
#   VOLNAME   volume name override (default: "Install Downright")
#   DMG_LAYOUT set to 0 to skip the optional Finder window arrangement
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
VOLNAME="${VOLNAME:-Install Downright}"
DMG="$OUT_DIR/Downright-$MARKETING_VERSION.dmg"
RW_DMG="$OUT_DIR/.Downright-$MARKETING_VERSION-rw.dmg"
DMG_LAYOUT="${DMG_LAYOUT:-1}"
DMG_BACKGROUND="${DMG_BACKGROUND:-$ROOT/Scripts/dmg-background.svg}"

echo "==> Packaging $APP"
echo "    -> $DMG"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"; rm -f "$RW_DMG"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Finder uses this hidden folder for the install note. Keep the source as SVG
# so the hand-drawn artwork stays reviewable, then rasterise it at the exact
# logical Finder window size. Finder maps a larger bitmap to the wrong canvas
# instead of treating it as a Retina asset, which crops the instructions.
if [ -n "$DMG_BACKGROUND" ]; then
    command -v sips >/dev/null 2>&1 || {
        echo "sips is required to rasterise the DMG background" >&2
        exit 1
    }
    [ -f "$DMG_BACKGROUND" ] || {
        echo "DMG background not found: $DMG_BACKGROUND" >&2
        exit 1
    }
    mkdir -p "$STAGING/.background"
    SOURCE_PNG="$STAGING/.background/dmg-background-source.png"
    sips -s format png "$DMG_BACKGROUND" --out "$SOURCE_PNG" >/dev/null
    sips -z 450 720 "$SOURCE_PNG" --out "$STAGING/.background/dmg-background.png" >/dev/null
    rm -f "$SOURCE_PNG"
    WIDTH="$(sips -g pixelWidth "$STAGING/.background/dmg-background.png" | awk '/pixelWidth/ { print $2 }')"
    HEIGHT="$(sips -g pixelHeight "$STAGING/.background/dmg-background.png" | awk '/pixelHeight/ { print $2 }')"
    [ "$WIDTH" = "720" ] && [ "$HEIGHT" = "450" ] || {
        echo "DMG background must be 720x450, got ${WIDTH:-unknown}x${HEIGHT:-unknown}" >&2
        exit 1
    }
    # Finder can be configured to show dotfiles. The artwork is implementation
    # detail, not a third item in the install window, so keep the folder hidden
    # even for those users.
    chflags hidden "$STAGING/.background" 2>/dev/null || true
fi

mkdir -p "$OUT_DIR"
# Build a writable image first so Finder can persist its icon-view metadata.
# Compress only after the layout has been written; applying AppleScript to a
# final UDZO image can appear to succeed while silently losing the .DS_Store.
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDRW \
    "$RW_DMG" >/dev/null

# Best-effort Finder polish. The image remains valid when Finder is not
# available (for example on a headless CI runner), but local release builds
# get a predictable window, icon scale, and drag-to-Applications layout.
if [ "$DMG_LAYOUT" = "1" ] && [ -f "$STAGING/.background/dmg-background.png" ] && command -v osascript >/dev/null 2>&1; then
    MOUNT_OUTPUT="$(hdiutil attach -nobrowse -noautoopen "$RW_DMG" 2>/dev/null || true)"
    MOUNT_POINT="$(printf '%s\n' "$MOUNT_OUTPUT" | sed -n 's#.*\(/Volumes/.*\)$#\1#p' | head -n 1)"
    if [ -n "$MOUNT_POINT" ]; then
        # hdiutil's source-folder copy does not reliably carry UF_HIDDEN into
        # the mounted filesystem. Apply it here, where Finder reads it.
        chflags hidden "$MOUNT_POINT/.background" 2>/dev/null || true
        if ! osascript - "$MOUNT_POINT" <<'APPLESCRIPT'
on run argv
    set volumeRoot to POSIX file (item 1 of argv) as alias
    tell application "Finder"
        tell disk (name of volumeRoot)
            open
            set theWindow to container window
            set current view of theWindow to icon view
            set toolbar visible of theWindow to false
            set statusbar visible of theWindow to false
            set bounds of theWindow to {120, 100, 840, 550}
            set viewOptions to icon view options of theWindow
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 112
            set text size of viewOptions to 13
            set background picture of viewOptions to file ".background:dmg-background.png"
            set position of item "Downright.app" of theWindow to {190, 240}
            set position of item "Applications" of theWindow to {530, 240}
            delay 0.5
            close
            open
        end tell
    end tell
end run
APPLESCRIPT
        then
            echo "warning: Finder layout could not be applied; using the default DMG window" >&2
        fi
        hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || hdiutil detach "$MOUNT_POINT" -force -quiet >/dev/null 2>&1 || true
    else
        echo "warning: DMG mounted without a discoverable volume path; using the default window" >&2
    fi
fi

# UDZO (zlib) is the safe default: readable by every macOS since 10.6.
hdiutil convert "$RW_DMG" \
    -format UDZO \
    -ov \
    -o "$DMG" >/dev/null

echo "==> Verifying image"
hdiutil verify "$DMG" >/dev/null

echo
echo "Built $DMG"
echo
echo "Next (release path):"
echo "  xcrun notarytool submit \"$DMG\" --keychain-profile \"AC_PASSWORD\" --wait"
echo "  xcrun stapler staple \"$DMG\""
echo "  (or run Scripts/sign-and-notarize.sh with MAKE_DMG=1, which does both)"
