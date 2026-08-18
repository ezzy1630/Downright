#!/bin/bash
# Build the host app and embed the native Quick Look extensions.
#
# SwiftPM checks the extension sources. Xcode builds the `.appex` bundles and
# places them in Contents/PlugIns, where Quick Look can discover them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-Release}"
SCRATCH="${SCRATCH:-.build-xcode}"
SWIFTPM_SCRATCH="${SWIFTPM_SCRATCH:-.build-main}"
DEBUG_INFORMATION_FORMAT="${DEBUG_INFORMATION_FORMAT:-dwarf-with-dsym}"
# shellcheck disable=SC1091
source "$ROOT/Config/version.env"
# PRODUCTION=1 embeds the Sparkle feed configuration and the real public key.
PRODUCTION="${PRODUCTION:-0}"
BUILD="$("$ROOT/Scripts/build-number.sh")"

command -v xcodegen >/dev/null || {
    echo "xcodegen is required. Install it with: brew install xcodegen" >&2
    exit 1
}

echo "==> Generating app icon"
"$ROOT/Scripts/make-icon.sh" "$ROOT/Resources/AppIcon.icns"

echo "==> Generating Downright.xcodeproj"
xcodegen generate --spec project.yml

if [ "$PRODUCTION" = "1" ]; then
    "$ROOT/Scripts/prepare-release-info-plist.sh"
elif [ ! -f "$ROOT/Config/Release-Info.plist" ]; then
    cp "$ROOT/Config/Downright-Info.plist" "$ROOT/Config/Release-Info.plist"
fi

echo "==> Building Downright.app ($CONFIGURATION, build $BUILD)"
xcodebuild \
    -project Downright.xcodeproj \
    -scheme Downright \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$SCRATCH" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=NO \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    DEBUG_INFORMATION_FORMAT="$DEBUG_INFORMATION_FORMAT" \
    build

APP="$ROOT/$SCRATCH/Build/Products/$CONFIGURATION/Downright.app"

echo "==> Embedding Sparkle.framework"
# XcodeGen's `embed: true` for an SPM framework resolves the copy phase to a
# bare product name ("Sparkle") instead of the versioned Sparkle.framework
# bundle, so the embed fails before the app is signed.  Link the framework in
# the project but copy it into the bundle by hand — the same approach the
# SwiftPM path uses, and deterministic across XcodeGen/Xcode versions.
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
SPARKLE_SOURCE=""
for candidate in \
    "$ROOT/$SCRATCH/Build/Products/$CONFIGURATION/Sparkle.framework" \
    "$ROOT/$SCRATCH/Build/Products/$CONFIGURATION/PackageFrameworks/Sparkle.framework"; do
    if [ -d "$candidate" ]; then
        SPARKLE_SOURCE="$candidate"
        break
    fi
done
if [ -n "$SPARKLE_SOURCE" ]; then
    rm -rf "$FRAMEWORKS/Sparkle.framework"
    cp -R "$SPARKLE_SOURCE" "$FRAMEWORKS/"
else
    echo "    WARNING: Sparkle.framework not found in Xcode products; bundle has no updater."
fi

echo "==> Embedding down CLI"
# SwiftPM may place products directly under the scratch directory or under a
# target-triple directory, depending on the active toolchain. Ask SwiftPM for
# the active binary directory instead of assuming one of those layouts.
swift build -c release --scratch-path "$SWIFTPM_SCRATCH" --product down
CLI_BIN="$(swift build -c release --scratch-path "$SWIFTPM_SCRATCH" --product down --show-bin-path)/down"
test -x "$CLI_BIN"
cp "$CLI_BIN" "$APP/Contents/MacOS/down"

echo "==> Flattening resource bundles"
# Xcode emits SwiftPM resource bundles as deep bundles (Contents/Resources/…),
# SwiftPM emits them flat, and flat is the layout everything ships with: the
# resolvers probe raw paths (MathFontBundle.isAvailable) and verify-bundle.sh
# asserts the flat files.  Lift Contents/Resources to the bundle root wherever
# a nested bundle appears — host and .appex alike — so both pipelines ship one
# layout.  Runs before signing: nothing signed yet may be mutated afterwards.
while IFS= read -r bundle; do
    deep="$bundle/Contents/Resources"
    [ -d "$deep" ] || continue
    ditto "$deep" "$bundle"
    rm -rf "$bundle/Contents"
done < <(find "$APP" -type d -name "*.bundle")

echo "==> Embedding Spotlight importer"
APP="$APP" SPOTLIGHT_SCRATCH="$SWIFTPM_SCRATCH" \
    SPOTLIGHT_CONFIGURATION=release \
    "$ROOT/Scripts/bundle-spotlight.sh"

# Sign inside-out, even for the ad-hoc QA bundle.  Re-sealing a child after its
# parent invalidates the parent's resource envelope and hides release-only bugs.
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
    SPARKLE_VERSION="$SPARKLE/Versions/B"
    codesign --force --sign - "$SPARKLE_VERSION/XPCServices/Installer.xpc"
    codesign --force --preserve-metadata=entitlements --sign - \
        "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
    codesign --force --sign - "$SPARKLE_VERSION/Autoupdate"
    codesign --force --sign - "$SPARKLE_VERSION/Updater.app"
    codesign --force --sign - "$SPARKLE"
fi
for appex in "$APP"/Contents/PlugIns/*.appex; do
    [ -e "$appex" ] || continue
    codesign --force --sign - --entitlements "$ROOT/Config/QuickLook.entitlements" \
        "$appex"
done
codesign --force --sign - "$APP/Contents/MacOS/down"
codesign --force --sign - "$APP"

echo "==> Verifying bundle layout"
# ${VAR:+x} expands for ANY non-empty value (including "0"); a dev bundle
# must not run the production feed/key checks.
if [ "$PRODUCTION" = "1" ]; then
    "$ROOT/Scripts/verify-bundle.sh" "$APP" --production
else
    "$ROOT/Scripts/verify-bundle.sh" "$APP"
fi

echo
echo "Built $APP"
echo "Quick Look bundles:"
find "$APP/Contents/PlugIns" -maxdepth 1 -type d -name '*.appex' -print
