#!/bin/bash
# Sign, notarize, and staple a production Downright.app by hand.
#
# This is the manual equivalent of the release workflow's signing steps
# (.github/workflows/release.yml), kept in one place so an offline release is
# not a copy-paste archaeology session.  It never uses `codesign --deep` — every
# nested executable (Sparkle framework, its XPC helpers, the Quick Look
# extensions, the down CLI) is signed individually, then the host last, then
# each is verified.
#
# Usage:
#   Scripts/sign-and-notarize.sh [path/to/Downright.app]
#
# With no argument the app is located the same way as Scripts/make-dmg.sh
# (.build-xcode Release first, then .build-main/bundle).
#
# Required env:
#   IDENTITY     "Developer ID Application: Your Name (TEAMID)"
#                from `security find-identity -v -p codesigning`
#   Notarytool credentials — one of:
#     KEYCHAIN_PROFILE=AC_PASSWORD        # xcrun notarytool store-credentials
#     or the three APPLE_API_* vars below (App Store Connect API key)
#
# Optional env:
#   MAKE_DMG=1      also build Downright-<version>.dmg and notarize+staple it
#   NO_NOTARIZE=1   sign and verify only (real identity, no notary step)
#
# Example:
#   IDENTITY="Developer ID Application: Jane Doe (TEAMID12345)" \
#   KEYCHAIN_PROFILE=AC_PASSWORD \
#   MAKE_DMG=1 \
#   Scripts/sign-and-notarize.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source Config/version.env

IDENTITY="${IDENTITY:?set IDENTITY to 'Developer ID Application: Name (TEAMID)'}"
NO_NOTARIZE="${NO_NOTARIZE:-0}"

if [ "$NO_NOTARIZE" = "0" ] && [ -z "${KEYCHAIN_PROFILE:-}" ] \
    && [ -z "${APPLE_API_KEY_ID:-}" ]; then
    echo "set KEYCHAIN_PROFILE (or APPLE_API_KEY_ID/APPLE_API_ISSUER_ID/APPLE_API_PRIVATE_KEY_P8)" >&2
    echo "or run with NO_NOTARIZE=1 to sign only" >&2
    exit 1
fi

APP="${APP:-${1:-}}"
if [ -z "$APP" ] && [ -d ".build-xcode/Build/Products/Release/Downright.app" ]; then
    APP=".build-xcode/Build/Products/Release/Downright.app"
elif [ -z "$APP" ] && [ -d ".build-main/bundle/Downright.app" ]; then
    APP=".build-main/bundle/Downright.app"
fi
[ -n "$APP" ] && [ -d "$APP" ] || {
    echo "usage: Scripts/sign-and-notarize.sh [path/to/Downright.app]" >&2
    exit 1
}
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$1"; }
sign_preserving_entitlements() {
    codesign --force --options runtime --timestamp \
        --preserve-metadata=entitlements --sign "$IDENTITY" "$1"
}
sign_quicklook() {
    codesign --force --options runtime --timestamp \
        --entitlements "$ROOT/Config/QuickLook.entitlements" --sign "$IDENTITY" "$1"
}

echo "==> Signing every nested executable (no --deep)"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE/Versions/B"
sign "$SPARKLE_VERSION/XPCServices/Installer.xpc"
sign_preserving_entitlements "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
sign "$SPARKLE_VERSION/Autoupdate"
sign "$SPARKLE_VERSION/Updater.app"
sign "$SPARKLE"
for appex in "$APP"/Contents/PlugIns/*.appex; do
    [ -d "$appex" ] && sign_quicklook "$appex"
done
sign "$APP/Contents/MacOS/down"
sign "$APP"

echo "==> Verifying signatures"
for item in "$APP" "$APP/Contents/Frameworks/Sparkle.framework" \
            "$APP/Contents/Frameworks/Sparkle.framework"/Versions/*/XPCServices/*.xpc \
            "$APP/Contents/Frameworks/Sparkle.framework"/Versions/*/Autoupdate \
            "$APP/Contents/Frameworks/Sparkle.framework"/Versions/*/Updater.app \
            "$APP/Contents/MacOS/down" "$APP"/Contents/PlugIns/*.appex; do
    [ -e "$item" ] || continue
    codesign --verify --strict --verbose=2 "$item"
done

if [ "$NO_NOTARIZE" = "1" ]; then
    echo
    echo "Signed only (NO_NOTARIZE=1): $APP"
    exit 0
fi

echo "==> Notarizing"
ZIP="$ROOT/dist/Downright-$MARKETING_VERSION.zip"
NOTARY_ZIP="$ROOT/dist/.Downright-$MARKETING_VERSION-notarization.zip"
mkdir -p "$ROOT/dist"
ditto -c -k --keepParent --sequesterRsrc "$APP" "$NOTARY_ZIP"

# The ephemeral API key must outlive EVERY submit that references it (the zip
# and, with MAKE_DMG=1, the DMG), so it is removed by the EXIT trap, not inline.
CLEANUP=("$NOTARY_ZIP")
trap 'rm -f "${CLEANUP[@]}"' EXIT
if [ -n "${KEYCHAIN_PROFILE:-}" ]; then
    NOTARY=(--keychain-profile "$KEYCHAIN_PROFILE")
else
    printf '%s' "${APPLE_API_PRIVATE_KEY_P8:-}" > /tmp/downright-AuthKey.p8
    CLEANUP+=(/tmp/downright-AuthKey.p8)
    NOTARY=(--key /tmp/downright-AuthKey.p8 --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
fi
xcrun notarytool submit "$NOTARY_ZIP" "${NOTARY[@]}" --wait --timeout 20m

echo "==> Stapling and verifying"
xcrun stapler staple "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=4 "$APP"
xcrun stapler validate "$APP"

# The archive submitted above necessarily predates stapling. Rebuild the
# artifact users receive so the offline Gatekeeper ticket is inside the zip.
rm -f "$ZIP"
ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"

if [ "${MAKE_DMG:-0}" = "1" ]; then
    echo "==> Building and notarizing the DMG"
    DMG="$ROOT/dist/Downright-$MARKETING_VERSION.dmg"
    OUT_DIR="$ROOT/dist" Scripts/make-dmg.sh "$APP"
    xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait --timeout 20m
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi

echo
echo "Signed, notarized, and stapled:"
echo "  $APP"
echo "  $ZIP"
[ "${MAKE_DMG:-0}" = "1" ] && echo "  $DMG"
echo
echo "Smoke-test by copying the zip elsewhere, expanding, and launching once."
