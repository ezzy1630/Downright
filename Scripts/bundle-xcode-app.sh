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

PLIST_ARG=()
if [ "$PRODUCTION" = "1" ]; then
    "$ROOT/Scripts/prepare-release-info-plist.sh"
    PLIST_ARG=(-overrideInBuildSettings INFOPLIST_FILE=Config/Release-Info.plist)
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
    "${PLIST_ARG[@]}" \
    build

APP="$ROOT/$SCRATCH/Build/Products/$CONFIGURATION/Downright.app"

echo "==> Embedding down CLI"
swift build -c release --scratch-path "$SWIFTPM_SCRATCH" --product down
cp "$ROOT/$SWIFTPM_SCRATCH/release/down" "$APP/Contents/MacOS/down"

# Sign nested Sparkle helpers/frameworks and the appex bundles individually,
# then the app — never codesign --deep for the production path.
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework" 2>/dev/null || true
fi
for appex in "$APP"/Contents/PlugIns/*.appex; do
    [ -e "$appex" ] || continue
    codesign --force --sign - "$appex" 2>/dev/null || true
done
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
