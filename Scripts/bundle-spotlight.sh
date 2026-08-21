#!/bin/bash
# Build and embed Downright's macOS Spotlight importer.
#
# A Spotlight importer is a classic CFPlugIn, not an app extension. The SwiftPM
# target type-checks and links the importer ABI; this script supplies the
# bundle layout that mdworker discovers inside a macOS app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="${APP:?APP must point to the Downright.app being assembled}"
SPOTLIGHT_SCRATCH="${SPOTLIGHT_SCRATCH:-${SCRATCH:-.build-main}}"
SPOTLIGHT_CONFIGURATION="${SPOTLIGHT_CONFIGURATION:-release}"

[ -d "$APP/Contents" ] || {
    echo "error: not an app bundle: $APP" >&2
    exit 1
}

PLIST_VALUE() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"
}

VERSION="$(PLIST_VALUE CFBundleShortVersionString)"
BUILD="$(PLIST_VALUE CFBundleVersion)"
HOST_BUNDLE_IDENTIFIER="$(PLIST_VALUE CFBundleIdentifier)"
SPOTLIGHT_BUNDLE_IDENTIFIER="$HOST_BUNDLE_IDENTIFIER.spotlight"

echo "==> Building Spotlight importer ($SPOTLIGHT_CONFIGURATION)"
swift build \
    -c "$SPOTLIGHT_CONFIGURATION" \
    --scratch-path "$SPOTLIGHT_SCRATCH" \
    --product DownrightSpotlightImporter
BIN_DIR="$(swift build \
    -c "$SPOTLIGHT_CONFIGURATION" \
    --scratch-path "$SPOTLIGHT_SCRATCH" \
    --product DownrightSpotlightImporter \
    --show-bin-path)"
SOURCE="$BIN_DIR/libDownrightSpotlightImporter.dylib"
[ -f "$SOURCE" ] || {
    echo "error: SwiftPM did not produce $SOURCE" >&2
    exit 1
}

IMPORTER="$APP/Contents/Library/Spotlight/DownrightSpotlight.mdimporter"
EXECUTABLE="$IMPORTER/Contents/MacOS/DownrightSpotlight"
RESOURCES="$IMPORTER/Contents/Resources"
rm -rf "$IMPORTER"
mkdir -p "$(dirname "$EXECUTABLE")" "$RESOURCES"

cp "$SOURCE" "$EXECUTABLE"
sed \
    -e 's|\$(MARKETING_VERSION)|'"$VERSION"'|g' \
    -e 's|\$(CURRENT_PROJECT_VERSION)|'"$BUILD"'|g' \
    -e 's|com\.ezzy\.downright\.spotlight|'"$SPOTLIGHT_BUNDLE_IDENTIFIER"'|g' \
    "$ROOT/Config/DownrightSpotlight-Info.plist" \
    > "$IMPORTER/Contents/Info.plist"
cp "$ROOT/Resources/Spotlight/schema.xml" "$RESOURCES/schema.xml"

# The importer is nested code. Seal it before the host is sealed so both
# ad-hoc development bundles and the production workflow have the same order.
codesign --force --sign - \
    --identifier "$SPOTLIGHT_BUNDLE_IDENTIFIER.binary" \
    "$EXECUTABLE" 2>/dev/null \
    || echo "    (codesign unavailable, continuing unsigned)"
codesign --force --sign - \
    --identifier "$SPOTLIGHT_BUNDLE_IDENTIFIER" \
    "$IMPORTER" 2>/dev/null \
    || echo "    (codesign unavailable, continuing unsigned)"

echo "    embedded $IMPORTER"
