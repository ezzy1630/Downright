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
BUILD="$("$ROOT/Scripts/build-number.sh")"

command -v xcodegen >/dev/null || {
    echo "xcodegen is required. Install it with: brew install xcodegen" >&2
    exit 1
}

echo "==> Generating app icon"
"$ROOT/Scripts/make-icon.sh" "$ROOT/Resources/AppIcon.icns"

echo "==> Generating Downright.xcodeproj"
xcodegen generate --spec project.yml

echo "==> Building Downright.app ($CONFIGURATION, build $BUILD)"
xcodebuild \
    -project Downright.xcodeproj \
    -scheme Downright \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$SCRATCH" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=NO \
    CURRENT_PROJECT_VERSION="$BUILD" \
    build

APP="$ROOT/$SCRATCH/Build/Products/$CONFIGURATION/Downright.app"

echo "==> Embedding down CLI"
swift build -c release --scratch-path "$SWIFTPM_SCRATCH" --product down
cp "$ROOT/$SWIFTPM_SCRATCH/release/down" "$APP/Contents/MacOS/down"
codesign --force --deep --sign - "$APP"

echo
echo "Built $APP"
echo "Quick Look bundles:"
find "$APP/Contents/PlugIns" -maxdepth 1 -type d -name '*.appex' -print
