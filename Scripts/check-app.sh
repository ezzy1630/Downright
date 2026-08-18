#!/bin/bash
# Build the Xcode app bundle, embed the filesystem Spotlight importer, and run
# the activated-app acceptance suite against that exact bundle.
#
# SwiftPM proves the parser and renderer in isolation. This lane proves the
# user-visible boundary: a signed app launches, opens a real file, completes a
# TextKit display cycle, exposes the mode controls to accessibility, and keeps
# source editing live. It intentionally uses a separate derived-data path so a
# stale installed app cannot satisfy the test.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v xcodegen >/dev/null || {
    echo "check-app: xcodegen is required (brew install xcodegen)" >&2
    exit 1
}
command -v xcodebuild >/dev/null || {
    echo "check-app: xcodebuild is required" >&2
    exit 1
}

APP_ACCEPTANCE_SCRATCH="${APP_ACCEPTANCE_SCRATCH:-.build-app-acceptance}"
SPOTLIGHT_SCRATCH="${SPOTLIGHT_SCRATCH:-.build-app-acceptance-spm}"
CONFIGURATION="${APP_ACCEPTANCE_CONFIGURATION:-Debug}"
SPOTLIGHT_CONFIGURATION="${APP_ACCEPTANCE_SPOTLIGHT_CONFIGURATION:-}"
APP_ACCEPTANCE_PRODUCTION="${APP_ACCEPTANCE_PRODUCTION:-0}"
APP_ACCEPTANCE_MARKETING_VERSION="${APP_ACCEPTANCE_MARKETING_VERSION:-}"
APP_ACCEPTANCE_BUILD_NUMBER="${APP_ACCEPTANCE_BUILD_NUMBER:-}"
DOWNRIGHT_UPDATER_SMOKE="${DOWNRIGHT_UPDATER_SMOKE:-0}"
LOG_TAG="$(printf '%s' "$APP_ACCEPTANCE_SCRATCH" | tr -c 'A-Za-z0-9._-' '-')"
LOG_DIR="${TMPDIR:-/tmp}"
BUILD_LOG="$LOG_DIR/downright-app-build-$LOG_TAG.log"
TEST_LOG="$LOG_DIR/downright-app-test-$LOG_TAG.log"
HOST_ARCH="$(uname -m)"
DESTINATION="platform=macOS,arch=$HOST_ARCH"

# shellcheck disable=SC1091
source "$ROOT/Config/version.env"
MARKETING_VERSION="${APP_ACCEPTANCE_MARKETING_VERSION:-$MARKETING_VERSION}"
if [ -n "$APP_ACCEPTANCE_BUILD_NUMBER" ]; then
    BUILD_NUMBER="$APP_ACCEPTANCE_BUILD_NUMBER"
else
    BUILD_NUMBER="$("$ROOT/Scripts/build-number.sh")"
fi
if [ -z "$SPOTLIGHT_CONFIGURATION" ]; then
    SPOTLIGHT_CONFIGURATION="$(printf '%s' "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')"
fi
HOST_BUNDLE_IDENTIFIER="com.ezzy.downright.acceptance"

case "$APP_ACCEPTANCE_PRODUCTION" in
    0) ;;
    1)
        HOST_BUNDLE_IDENTIFIER="com.ezzy.downright"
        : "${SPARKLE_ED25519_PUBLIC_KEY:?check-app: production mode requires SPARKLE_ED25519_PUBLIC_KEY}"
        ;;
    *)
        echo "check-app: APP_ACCEPTANCE_PRODUCTION must be 0 or 1" >&2
        exit 1
        ;;
esac

echo "==> Generating Downright.xcodeproj"
xcodegen generate --spec project.yml

if [ "$APP_ACCEPTANCE_PRODUCTION" = "1" ]; then
    echo "==> Preparing production updater configuration"
    "$ROOT/Scripts/prepare-release-info-plist.sh"
fi

echo "==> Building the activated-app host and UI test bundle"
xcodebuild \
    -project Downright.xcodeproj \
    -scheme Downright \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$APP_ACCEPTANCE_SCRATCH" \
    -clonedSourcePackagesDirPath "$APP_ACCEPTANCE_SCRATCH/SourcePackages" \
    -destination "$DESTINATION" \
    -disableAutomaticPackageResolution \
    -skipPackageUpdates \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=NO \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    DOWNRIGHT_HOST_BUNDLE_IDENTIFIER="$HOST_BUNDLE_IDENTIFIER" \
    build-for-testing 2>&1 | tee "$BUILD_LOG"

APP="$ROOT/$APP_ACCEPTANCE_SCRATCH/Build/Products/$CONFIGURATION/Downright.app"
[ -d "$APP" ] || {
    echo "check-app: expected app bundle was not produced: $APP" >&2
    exit 1
}

echo "==> Embedding the CLI and flattening Xcode resource bundles"
swift build -c release --scratch-path "$SPOTLIGHT_SCRATCH" --product down
CLI_BIN="$(swift build -c release --scratch-path "$SPOTLIGHT_SCRATCH" --product down --show-bin-path)/down"
[ -x "$CLI_BIN" ] || {
    echo "check-app: SwiftPM did not produce the down CLI: $CLI_BIN" >&2
    exit 1
}
cp "$CLI_BIN" "$APP/Contents/MacOS/down"

# Xcode places SwiftPM resources at bundle/Contents/Resources, while the
# runtime resolvers and the shared bundle verifier use the flat layout. Lift
# every nested resource bundle before re-signing the modified app.
while IFS= read -r bundle; do
    deep="$bundle/Contents/Resources"
    [ -d "$deep" ] || continue
    ditto "$deep" "$bundle"
    rm -rf "$bundle/Contents"
done < <(find "$APP" -type d -name "*.bundle")

echo "==> Embedding the filesystem Spotlight importer"
APP="$APP" \
    SPOTLIGHT_SCRATCH="$SPOTLIGHT_SCRATCH" \
    SPOTLIGHT_CONFIGURATION="$SPOTLIGHT_CONFIGURATION" \
    "$ROOT/Scripts/bundle-spotlight.sh"

# Flattening invalidated the Xcode extension seals, and build-for-testing signed
# the host before the importer and CLI existed. Re-seal children first and the
# host last; no nested code is changed after this point.
for appex in "$APP"/Contents/PlugIns/*.appex; do
    [ -e "$appex" ] || continue
    codesign --force --sign - --entitlements "$ROOT/Config/QuickLook.entitlements" "$appex"
done
echo "==> Re-sealing the acceptance host"
codesign --force --sign - "$APP"

echo "==> Verifying the exact acceptance bundle"
if [ "$APP_ACCEPTANCE_PRODUCTION" = "1" ]; then
    "$ROOT/Scripts/verify-bundle.sh" "$APP" --production
else
    "$ROOT/Scripts/verify-bundle.sh" "$APP"
fi

echo "==> Running activated-app acceptance tests"
XCTESTRUN="$(find "$ROOT/$APP_ACCEPTANCE_SCRATCH/Build/Products" -maxdepth 1 -name '*.xctestrun' -print -quit)"
[ -n "$XCTESTRUN" ] || {
    echo "check-app: build-for-testing did not produce an xctestrun manifest" >&2
    exit 1
}
UI_TARGET_PATH="$(/usr/libexec/PlistBuddy -c 'Print :DownrightUITests:UITargetAppPath' "$XCTESTRUN" 2>/dev/null || true)"
# Xcode 26 can omit UITargetAppPath when a macOS UI-test target is generated
# from XcodeGen, even though the target's build settings contain the value.
# The test manifest is the final contract consumed by test-without-building;
# repair the missing key from the exact bundle we just built, then validate it
# before launching XCTest. A present but different path remains a hard failure.
EXPECTED_UI_TARGET_PATH="__TESTROOT__/$CONFIGURATION/Downright.app"
if [ -z "$UI_TARGET_PATH" ]; then
    /usr/libexec/PlistBuddy -c "Add :DownrightUITests:UITargetAppPath string $EXPECTED_UI_TARGET_PATH" "$XCTESTRUN"
    UI_TARGET_PATH="$(/usr/libexec/PlistBuddy -c 'Print :DownrightUITests:UITargetAppPath' "$XCTESTRUN")"
fi
[ "$UI_TARGET_PATH" = "$EXPECTED_UI_TARGET_PATH" ] || {
    echo "check-app: xctestrun manifest has no exact UI target app path: $XCTESTRUN" >&2
    exit 1
}
DOWNRIGHT_UPDATER_SMOKE="$DOWNRIGHT_UPDATER_SMOKE" \
xcodebuild \
    test-without-building \
    -xctestrun "$XCTESTRUN" \
    -destination "$DESTINATION" \
    -only-testing:DownrightUITests/DownrightActivatedAppTests \
    -parallel-testing-enabled NO \
    -test-timeouts-enabled YES 2>&1 | tee "$TEST_LOG"

echo
echo "Activated-app acceptance passed"
echo "    app: $APP"
echo "    build log: $BUILD_LOG"
echo "    test log: $TEST_LOG"
