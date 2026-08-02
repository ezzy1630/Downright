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

command -v xcodegen >/dev/null || {
    echo "xcodegen is required. Install it with: brew install xcodegen" >&2
    exit 1
}

echo "==> Generating Downright.xcodeproj"
xcodegen generate --spec project.yml

echo "==> Building Downright.app ($CONFIGURATION)"
xcodebuild \
    -project Downright.xcodeproj \
    -scheme Downright \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$SCRATCH" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

APP="$ROOT/$SCRATCH/Build/Products/$CONFIGURATION/Downright.app"
echo
echo "Built $APP"
echo "Quick Look bundles:"
find "$APP/Contents/PlugIns" -maxdepth 1 -type d -name '*.appex' -print
