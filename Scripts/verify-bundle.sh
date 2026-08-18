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
#   * the host app and each .appex carry their own copy of every SwiftPM
#     resource bundle their code reaches for, at a path the resolvers look in
#   * host and extensions share the marketing/build versions
#   * --production: the stable bundle identity, signed feed, updater safety
#     flags, and Ed25519 public key all carry the release contract
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
    check "$(find "$FW" -maxdepth 8 -type d -name 'Downloader.xpc' -path '*/XPCServices/*' 2>/dev/null | grep -q . && echo 1 || echo 0)" "Sparkle Downloader XPC helper"
    check "$(find "$FW" -maxdepth 8 -type d -name 'Installer.xpc' -path '*/XPCServices/*' 2>/dev/null | grep -q . && echo 1 || echo 0)" "Sparkle Installer XPC helper"
    check "$([ -x "$FW/Versions/B/Autoupdate" ] && echo 1 || echo 0)" "Sparkle Autoupdate helper"
    check "$([ -d "$FW/Versions/B/Updater.app" ] && echo 1 || echo 0)" "Sparkle Updater app"
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

# --- Resource bundles --------------------------------------------------------
# Both resolvers — ThemeStore.resourceBundle and the vendored SwiftMath's
# MathResourceBundle (Vendor/SwiftMath/PATCHES.md) — look in Contents/Resources
# first for a deep bundle, so that is where these have to be.  Assert the exact
# files they open rather than the bundles around them: a truncated copy is the
# failure that shows up as "no math" months later.
check "$([ -f "$CONTENTS/Resources/Downright_MarkdownRender.bundle/Themes/paper-light.json" ] && echo 1 || echo 0)" \
      "host carries the MarkdownRender themes"
check "$([ -f "$CONTENTS/Resources/SwiftMath_SwiftMath.bundle/mathFonts.bundle/latinmodern-math.otf" ] && echo 1 || echo 0)" \
      "host carries the SwiftMath math fonts"

# --- Spotlight importer -----------------------------------------------------
# macOS discovers classic MDImporter bundles at this exact location. Keep the
# importer in the same bundle contract as Quick Look: the binary, schema, and
# metadata version must all travel with the app that owns them.
SPOTLIGHT="$CONTENTS/Library/Spotlight/DownrightSpotlight.mdimporter"
SPOTLIGHT_PLIST="$SPOTLIGHT/Contents/Info.plist"
SPOTLIGHT_BIN="$SPOTLIGHT/Contents/MacOS/DownrightSpotlight"
check "$([ -d "$SPOTLIGHT" ] && echo 1 || echo 0)" "Spotlight importer embedded"
check "$([ -x "$SPOTLIGHT_BIN" ] && echo 1 || echo 0)" "Spotlight importer executable present"
check "$([ -f "$SPOTLIGHT/Contents/Resources/schema.xml" ] && echo 1 || echo 0)" "Spotlight importer schema present"
check "$([ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$SPOTLIGHT_PLIST" 2>/dev/null || echo '')" = "BNDL" ] && echo 1 || echo 0)" \
      "Spotlight importer is a CFPlugIn bundle"
check "$([ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SPOTLIGHT_PLIST" 2>/dev/null || echo '')" = "DownrightSpotlight" ] && echo 1 || echo 0)" \
      "Spotlight importer executable name"
check "$(grep -q '8B08C4BF-415B-11D8-B3F9-0003936726FC' "$SPOTLIGHT_PLIST" 2>/dev/null && echo 1 || echo 0)" \
      "Spotlight importer declares the MDImporter plug-in type"
check "$(grep -q 'net.daringfireball.markdown' "$SPOTLIGHT_PLIST" 2>/dev/null && echo 1 || echo 0)" \
      "Spotlight importer claims Markdown UTI"
if [ -x "$SPOTLIGHT_BIN" ]; then
    SPOTLIGHT_BAD_DYLIBS="$(otool -L "$SPOTLIGHT_BIN" | tail -n +2 | grep -vE '\(architecture [^)]*\):$|@rpath|@executable_path|@loader_path|/usr/lib/|/System/|/Library/Frameworks/' || true)"
    check "$([ -z "$SPOTLIGHT_BAD_DYLIBS" ] && echo 1 || echo 0)" \
          "Spotlight importer has no absolute build-machine dylib paths"
fi

# --- Quick Look extensions ---------------------------------------------------
# Two .appex layouts reach this script: flat, as Scripts/bundle-quicklook.sh
# assembles them, and deep (Contents/MacOS, Contents/Resources) from Xcode.
# Resolve each file against both rather than pinning one pipeline's shape.
appex_plist() {
    local appex="$1"
    [ -f "$appex/Info.plist" ] && { echo "$appex/Info.plist"; return; }
    [ -f "$appex/Contents/Info.plist" ] && echo "$appex/Contents/Info.plist"
}

# An extension resolves resources from its own bundle: `Contents/Resources` for
# a deep .appex, the bundle root for a flat one.  Accept either — the two
# pipelines produce different shapes and both resolvers cover both.
appex_resource() {
    local appex="$1" relative="$2"
    [ -e "$appex/$relative" ] && { echo "$appex/$relative"; return; }
    [ -e "$appex/Contents/Resources/$relative" ] && echo "$appex/Contents/Resources/$relative"
}

appex_entitlement() {
    local appex="$1" key="$2"
    local key_path="${key//./\\.}"
    # `codesign -d` writes the entitlement plist to stderr along with its
    # diagnostics.  Keep that stream, isolate the XML, then query it.  Dropping
    # stderr made every correctly signed extension look unsandboxed.
    codesign -d --entitlements :- "$appex" 2>&1 \
        | awk '/<\?xml/{found=1} found{print} /<\/plist>/{exit}' \
        | plutil -extract "$key_path" raw -o - - 2>/dev/null \
        || true
}

if [ -d "$CONTENTS/PlugIns" ]; then
    check "$([ -d "$CONTENTS/PlugIns/DownrightQL.appex" ] && echo 1 || echo 0)" "DownrightQL.appex embedded"
    check "$([ -d "$CONTENTS/PlugIns/DownrightThumb.appex" ] && echo 1 || echo 0)" "DownrightThumb.appex embedded"

    # An extension resolves resources through its own Bundle.main, so nothing in
    # the host app's Contents/Resources is reachable from inside it: each .appex
    # needs its own copy of every resource bundle its linked code can ask for.
    for appex in "$CONTENTS"/PlugIns/*.appex; do
        [ -e "$appex" ] || continue
        NAME="$(basename "$appex")"
        check "$([ -n "$(appex_resource "$appex" Downright_MarkdownRender.bundle/Themes/paper-light.json)" ] && echo 1 || echo 0)" \
              "$NAME carries the MarkdownRender themes"
        # SwiftMath does not fail when its fonts are missing, it calls
        # fatalError — which is how one formula used to take the whole preview
        # down.  MathFontBundle degrades instead of trapping now, so a miss
        # here is no longer fatal, only silently worse; assert the exact file
        # SwiftMath opens first so it cannot regress unnoticed.
        check "$([ -n "$(appex_resource "$appex" SwiftMath_SwiftMath.bundle/mathFonts.bundle/latinmodern-math.otf)" ] && echo 1 || echo 0)" \
              "$NAME carries the SwiftMath math fonts"
        check "$([ "$(appex_entitlement "$appex" com.apple.security.app-sandbox)" = "true" ] && echo 1 || echo 0)" \
              "$NAME retains App Sandbox entitlement"
        check "$([ "$(appex_entitlement "$appex" com.apple.security.get-task-allow)" != "true" ] && echo 1 || echo 0)" \
              "$NAME omits get-task-allow"
    done
else
    check 0 "DownrightQL.appex embedded"
    check 0 "DownrightThumb.appex embedded"
fi

# --- Version consistency -----------------------------------------------------
host_short() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null || echo ""; }
host_build() { /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$1/Contents/Info.plist" 2>/dev/null || echo ""; }

HOST_SHORT="$(host_short "$APP")"
HOST_BUILD="$(host_build "$APP")"
[ -n "$HOST_SHORT" ] || { check 0 "host CFBundleShortVersionString readable"; exit 1; }

SPOTLIGHT_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SPOTLIGHT_PLIST" 2>/dev/null || echo '')"
SPOTLIGHT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SPOTLIGHT_PLIST" 2>/dev/null || echo '')"
check "$([ "$SPOTLIGHT_SHORT" = "$HOST_SHORT" ] && echo 1 || echo 0)" "Spotlight importer marketing version matches host"
check "$([ "$SPOTLIGHT_BUILD" = "$HOST_BUILD" ] && echo 1 || echo 0)" "Spotlight importer build version matches host"

for appex in "$CONTENTS"/PlugIns/*.appex; do
    [ -e "$appex" ] || continue
    # `|| true`: an .appex with neither plist would abort the script under
    # `set -e` before the check below could report it.
    EXT_PLIST="$(appex_plist "$appex" || true)"
    EXT_SHORT="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$EXT_PLIST" 2>/dev/null || echo "")"
    EXT_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$EXT_PLIST" 2>/dev/null || echo "")"
    check "$([ "$EXT_SHORT" = "$HOST_SHORT" ] && echo 1 || echo 0)" "$(basename "$appex") marketing version matches host"
    check "$([ "$EXT_BUILD" = "$HOST_BUILD" ] && echo 1 || echo 0)" "$(basename "$appex") build version matches host"
done

# Numeric, monotonically increasing CFBundleVersion is a release gate concern
# (the workflow supplies it); here we only require it to be numeric-looking.
check "$(echo "$HOST_BUILD" | grep -Eq '^[0-9]+([.][0-9]+)*$' && echo 1 || echo 0)" "CFBundleVersion '$HOST_BUILD' is numeric"

# --- Production configuration ------------------------------------------------
if [ "$PRODUCTION" = "1" ]; then
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$CONTENTS/Info.plist" 2>/dev/null || echo "")"
    FEED="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$CONTENTS/Info.plist" 2>/dev/null || echo "")"
    KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$CONTENTS/Info.plist" 2>/dev/null || echo "")"
    AUTO_CHECKS="$(/usr/libexec/PlistBuddy -c "Print :SUEnableAutomaticChecks" "$CONTENTS/Info.plist" 2>/dev/null || echo "")"
    AUTO_UPDATE="$(/usr/libexec/PlistBuddy -c "Print :SUAutomaticallyUpdate" "$CONTENTS/Info.plist" 2>/dev/null || echo "")"
    SIGNED_FEED="$(/usr/libexec/PlistBuddy -c "Print :SURequireSignedFeed" "$CONTENTS/Info.plist" 2>/dev/null || echo "")"
    VERIFY_BEFORE_EXTRACTION="$(/usr/libexec/PlistBuddy -c "Print :SUVerifyUpdateBeforeExtraction" "$CONTENTS/Info.plist" 2>/dev/null || echo "")"
    INTERVAL="$(/usr/libexec/PlistBuddy -c "Print :SUScheduledCheckInterval" "$CONTENTS/Info.plist" 2>/dev/null || echo "")"
    # A 32-byte Ed25519 public key is 44 base64 characters with one trailing
    # padding character.  Checking the shape catches accidental secret-name
    # injection, truncation, and placeholder values before signing starts.
    KEY_SHAPE='^[A-Za-z0-9+/]{43}=$'
    INTERVAL_OK=0
    if echo "$INTERVAL" | grep -Eq '^[0-9]+$' && [ "$INTERVAL" -gt 0 ]; then
        INTERVAL_OK=1
    fi
    check "$([ "$BUNDLE_ID" = "com.ezzy.downright" ] && echo 1 || echo 0)" "production bundle identifier stable"
    check "$([ "$FEED" = "https://ezzy1630.github.io/Downright/appcast.xml" ] && echo 1 || echo 0)" "production feed URL exact"
    check "$(echo "$KEY" | grep -Eq "$KEY_SHAPE" && echo 1 || echo 0)" "SUPublicEDKey is a 32-byte Ed25519 key"
    check "$([ "$AUTO_CHECKS" = "true" ] && echo 1 || echo 0)" "automatic update checks enabled"
    check "$([ "$AUTO_UPDATE" = "true" ] && echo 1 || echo 0)" "automatic update installation enabled"
    check "$([ "$SIGNED_FEED" = "true" ] && echo 1 || echo 0)" "signed appcast required"
    check "$([ "$VERIFY_BEFORE_EXTRACTION" = "true" ] && echo 1 || echo 0)" "update verified before extraction"
    check "$INTERVAL_OK" "scheduled update interval is positive"
else
    check 1 "updater-disabled configuration (dev bundle)"
fi

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "verify-bundle: $FAILURES failure(s)"
    exit 1
fi
echo "verify-bundle: bundle layout OK"
