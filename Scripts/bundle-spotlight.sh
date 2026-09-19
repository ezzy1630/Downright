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

# Match the assembled host, including universal archives built on Apple Silicon.
# The architectures are read into a variable first so the lookup can fail: a
# command substitution in a `for` word list is not caught by `set -e`, and an
# empty list would either abort on `set -u` (bash 3.2, which is what /bin/bash
# is on macOS) or quietly build host-only — the exact single-arch result this is
# here to prevent.
HOST_ARCHS="$(lipo -archs "$APP/Contents/MacOS/Downright" 2>/dev/null || true)"
[ -n "$HOST_ARCHS" ] || {
    echo "error: cannot read host architectures from $APP/Contents/MacOS/Downright" >&2
    exit 1
}

echo "==> Building Spotlight importer ($SPOTLIGHT_CONFIGURATION) for $HOST_ARCHS"
SOURCE="$SPOTLIGHT_SCRATCH-universal/libDownrightSpotlightImporter.dylib"
# shellcheck disable=SC2086  # HOST_ARCHS is a deliberate word list.
"$ROOT/Scripts/build-universal-product.sh" \
    DownrightSpotlightImporter \
    libDownrightSpotlightImporter.dylib \
    "$SPOTLIGHT_CONFIGURATION" \
    "$SPOTLIGHT_SCRATCH" \
    "$SOURCE" \
    $HOST_ARCHS

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
