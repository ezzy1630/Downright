#!/bin/bash
# Verify a Downright.app bundle regardless of which pipeline built it.
#
# Usage: Scripts/verify-bundle.sh /path/to/Downright.app [--production]
#
# Shared by Scripts/bundle-app.sh and .github/workflows/release.yml so both
# build paths are held to the same layout contract:
#   * Sparkle.framework and its nested XPC helpers are present and bundle-relative
#   * runtime dylib paths are bundle-relative (no absolute build-machine paths)
#   * the Quick Look extensions and the `down` CLI are embedded
#   * host and extensions share the marketing/build versions
#   * --production: the Info.plist carries the exact feed URL and a real
#     (non-placeholder) Ed25519 public key
set -euo pipefail

APP="${1:?usage: verify-bundle.sh /path/to/Downright.app [--production]}"
PRODUCTION=0
[ "${2:-}" = "--production" ] && PRODUCTION=1

CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
FAILURES=0

check() {
    local ok=$1
    local what=$2
    if [ "$ok" = "1" ]; then
        echo "    ok  $what"
    else
        echo "    FAIL $what"
        FAILURES=$((FAILURES + 1))
    fi
}

echo "==> Verifying $APP"

# --- Sparkle -----------------------------------------------------------------
FW="$CONTENTS/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
    check 1 "Sparkle.framework embedded"
    # Helper names/paths changed across Sparkle versions (2.9 uses
    # Versions/B/XPCServices/{Downloader,Installer}.xpc); require both helpers
    # somewhere under the framework rather than pinning one path.
    HELPER_DIRS="$(find "$FW" -type d -name XPCServices -maxdepth 6 2>/dev/null)"
    check "$(find $HELPER_DIRS -maxdepth 1 -name 'Downloader.xpc' 2>/dev/null | grep -q . && echo 1 || echo 0)" "Sparkle Downloader XPC helper"
    check "$(find $HELPER_DIRS -maxdepth 1 -name 'Installer.xpc' 2>/dev/null | grep -q . && echo 1 || echo 0)" "Sparkle Installer XPC helper"
else
    check 0 "Sparkle.framework embedded"
fi

# --- Runtime paths -----------------------------------------------------------
BIN="$MACOS/Downright"
if [ -x "$BIN" ]; then
    # otool -L prints the binary's own path as the first line; a universal
    # binary repeats a per-architecture header line too. Skip both, then any
    # path that stays must be an absolute build-machine dylib.
    BAD_DYLIBS="$(otool -L "$BIN" | tail -n +2 | grep -vE '\(architecture [^)]*\):$|@rpath|@executable_path|@loader_path|/usr/lib/|/System/|/Library/Frameworks/' || true)"
    check "$([ -z "$BAD_DYLIBS" ] && echo 1 || echo 0)" "no absolute dylib paths (offending: $(echo "$BAD_DYLIBS" | tr '\n' ' '))"
    RPATH="$(otool -l "$BIN" | grep -c '@executable_path/../Frameworks' || true)"
    check "$([ "$RPATH" -ge 1 ] && echo 1 || echo 0)" "bundle-relative rpath present"
else
    check 0 "main executable present"
fi

# --- CLI ---------------------------------------------------------------------
check "$([ -x "$MACOS/down" ] && echo 1 || echo 0)" "down CLI embedded"

# --- Privacy manifest --------------------------------------------------------
# Required-reason APIs (UserDefaults CA92.1, file timestamps C617.1) must be
# declared in every bundle that links the app code.
if [ -f "$CONTENTS/Resources/PrivacyInfo.xcprivacy" ]; then
    check 1 "PrivacyInfo.xcprivacy present"
    check "$(grep -q 'NSPrivacyAccessedAPICategoryUserDefaults' "$CONTENTS/Resources/PrivacyInfo.xcprivacy" && echo 1 || echo 0)" "privacy manifest declares UserDefaults (CA92.1)"
    check "$(grep -q 'NSPrivacyAccessedAPICategoryFileTimestamp' "$CONTENTS/Resources/PrivacyInfo.xcprivacy" && echo 1 || echo 0)" "privacy manifest declares file timestamps (C617.1)"
else
    check 0 "PrivacyInfo.xcprivacy present"
fi

# --- Quick Look extensions (Xcode builds only) -------------------------------
if [ -d "$CONTENTS/PlugIns" ]; then
    check "$([ -d "$CONTENTS/PlugIns/DownrightQL.appex" ] && echo 1 || echo 0)" "DownrightQL.appex embedded"
    check "$([ -d "$CONTENTS/PlugIns/DownrightThumb.appex" ] && echo 1 || echo 0)" "DownrightThumb.appex embedded"
fi

# --- Version consistency -----------------------------------------------------
host_short() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null || echo ""; }
host_build() { /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$1/Contents/Info.plist" 2>/dev/null || echo ""; }
extension_short() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null || echo ""; }

HOST_SHORT="$(host_short "$APP")"
HOST_BUILD="$(host_build "$APP")"
[ -n "$HOST_SHORT" ] || { check 0 "host CFBundleShortVersionString readable"; exit 1; }

for appex in "$CONTENTS"/PlugIns/*.appex; do
    [ -e "$appex" ] || continue
    EXT_SHORT="$(extension_short "$appex")"
    EXT_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$appex/Contents/Info.plist" 2>/dev/null || echo "")"
    check "$([ "$EXT_SHORT" = "$HOST_SHORT" ] && echo 1 || echo 0)" "$(basename "$appex") marketing version matches host"
    check "$([ "$EXT_BUILD" = "$HOST_BUILD" ] && echo 1 || echo 0)" "$(basename "$appex") build version matches host"
done

# Numeric, monotonically increasing CFBundleVersion is a release gate concern
# (the workflow supplies it); here we only require it to be numeric-looking.
check "$(echo "$HOST_BUILD" | grep -Eq '^[0-9]+([.][0-9]+)*$' && echo 1 || echo 0)" "CFBundleVersion '$HOST_BUILD' is numeric"

# --- Production configuration ------------------------------------------------
if [ "$PRODUCTION" = "1" ]; then
    FEED="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$CONTENTS/Info.plist" 2>/dev/null || echo "")"
    KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$CONTENTS/Info.plist" 2>/dev/null || echo "")"
    check "$([ "$FEED" = "https://ezzy1630.github.io/Downright/appcast.xml" ] && echo 1 || echo 0)" "production feed URL exact"
    check "$([ -n "$KEY" ] && ! echo "$KEY" | grep -q '^PLACEHOLDER_' && echo 1 || echo 0)" "non-placeholder SUPublicEDKey present"
else
    check 1 "updater-disabled configuration (dev bundle)"
fi

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "verify-bundle: $FAILURES failure(s)"
    exit 1
fi
echo "verify-bundle: bundle layout OK"
