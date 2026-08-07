#!/bin/bash
# Assemble Downright.app from the SwiftPM build products.
#
# SwiftPM can build the AppKit executable but not an .app bundle, so we build
# the bundle by hand.  This keeps the whole project buildable with the Command
# Line Tools alone — no Xcode project to keep in sync, no .pbxproj merge
# conflicts.  The Quick Look extensions are the one exception: an .appex has to
# be produced by Xcode, see Docs/QUICKLOOK.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-release}"
SCRATCH="${SCRATCH:-.build-main}"
APP_NAME="Downright"
BUNDLE_ID="com.ezzy.downright"
# shellcheck disable=SC1091
source "$ROOT/Config/version.env"
VERSION="$MARKETING_VERSION"
# PRODUCTION=1 adds the Sparkle feed configuration; dev bundles omit it, which
# disables the updater (see UpdateCoordinator.isConfigured).
PRODUCTION="${PRODUCTION:-0}"
BUILD="$("$ROOT/Scripts/build-number.sh")"

OUT="$ROOT/$SCRATCH/bundle"
APP="$OUT/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> Generating app icon"
"$ROOT/Scripts/make-icon.sh" "$ROOT/Resources/AppIcon.icns"

echo "==> Building ($CONFIGURATION, build $BUILD)"
swift build -c "$CONFIGURATION" --scratch-path "$SCRATCH" --product Downright
swift build -c "$CONFIGURATION" --scratch-path "$SCRATCH" --product down

BIN_DIR="$ROOT/$SCRATCH/$CONFIGURATION"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BIN_DIR/Downright" "$MACOS/$APP_NAME"
cp "$BIN_DIR/down" "$MACOS/down"

# SwiftPM resource bundles (themes, SwiftMath's math fonts).  Contents/Resources
# is where both resolvers look first for a deep bundle — ThemeStore.resourceBundle
# and the vendored SwiftMath's MathResourceBundle — and it is the only place a
# .app may keep them: codesign rejects anything but Contents at the bundle root.
# verify-bundle.sh asserts the individual files at the end of this script.
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$RESOURCES/"
done

printf 'APPL????' > "$CONTENTS/PkgInfo"

# Document types.  §10 lists the UTIs; .txt is deliberately excluded from the
# default set so we do not steal plain text from TextEdit — it is opt-in via
# the Finder's "Open With → Always Open With".
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSAppleEventsUsageDescription</key><string>Downright uses Terminal to open files in your \$EDITOR.</string>
    <key>NSHumanReadableCopyright</key><string>MIT licensed.</string>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict><key>default</key><string>Open Markdown in Downright</string></dict>
            <key>NSMessage</key><string>openMarkdownInDownright</string>
            <key>NSSendTypes</key>
            <array>
                <string>public.file-url</string>
                <string>public.utf8-plain-text</string>
            </array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Markdown Document</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>net.daringfireball.markdown</string>
                <string>com.ezzy.downright.markdown</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>md</string><string>markdown</string><string>mdown</string>
                <string>mkd</string><string>mdx</string><string>mdc</string>
                <string>qmd</string><string>rmd</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Plain Text</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.plain-text</string></array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>net.daringfireball.markdown</string>
            <key>UTTypeDescription</key><string>Markdown Document</string>
            <key>UTTypeConformsTo</key><array><string>public.plain-text</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>md</string><string>markdown</string><string>mdown</string><string>mkd</string></array>
                <key>public.mime-type</key><array><string>text/markdown</string></array>
            </dict>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.ezzy.downright.markdown</string>
            <key>UTTypeDescription</key><string>Extended Markdown Document</string>
            <key>UTTypeConformsTo</key><array><string>public.plain-text</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>mdx</string><string>mdc</string><string>qmd</string><string>rmd</string></array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
cp "$ROOT/Resources/AppIcon.png" "$RESOURCES/AppIcon.png"
# The tour.  AppDelegate looks it up with Bundle.main and hides the start
# window's guide action when it is absent, so a bundle without this file is
# degraded but not broken.
cp "$ROOT/Resources/Welcome.md" "$RESOURCES/Welcome.md"
# Privacy manifest: required-reason APIs (UserDefaults, file timestamps) must
# be declared per bundle.  Xcode builds get this via project.yml resources;
# the SwiftPM bundle copies it here so both pipelines ship the same manifest.
cp "$ROOT/Resources/PrivacyInfo.xcprivacy" "$RESOURCES/PrivacyInfo.xcprivacy"

echo "==> Embedding Sparkle.framework"
FRAMEWORKS="$CONTENTS/Frameworks"
mkdir -p "$FRAMEWORKS"
if [ -d "$BIN_DIR/Sparkle.framework" ]; then
    cp -R "$BIN_DIR/Sparkle.framework" "$FRAMEWORKS/"
    # SwiftPM links the executable against the framework with an rpath that
    # points into the scratch build directory.  Inside a relocated bundle that
    # rpath is wrong, so add the bundle-relative one; the stale entry is
    # harmless.
    install_name_tool -add_rpath @executable_path/../Frameworks "$MACOS/$APP_NAME" 2>/dev/null || true
else
    echo "    WARNING: Sparkle.framework not found in SwiftPM products; bundle has no updater."
fi

if [ "$PRODUCTION" = "1" ]; then
    [ -n "${SPARKLE_ED25519_PUBLIC_KEY:-}" ] || {
        echo "PRODUCTION=1 requires SPARKLE_ED25519_PUBLIC_KEY" >&2
        exit 1
    }
    /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$CONTENTS/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUAutomaticallyUpdate bool true" "$CONTENTS/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUScheduledCheckInterval integer 86400" "$CONTENTS/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUVerifyUpdateBeforeExtraction bool true" "$CONTENTS/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SURequireSignedFeed bool true" "$CONTENTS/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUEnableSystemProfiling bool false" "$CONTENTS/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://ezzy1630.github.io/Downright/appcast.xml" "$CONTENTS/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_ED25519_PUBLIC_KEY" "$CONTENTS/Info.plist"
else
    echo "    updater disabled: no Sparkle Info.plist keys in this dev bundle"
fi

echo "==> Signing (ad-hoc)"
# Sign Sparkle separately first (its XPC helpers are nested code), then the
# app without --deep so the framework's signature is preserved.  --deep is a
# development convenience only; the release pipeline signs every nested item
# explicitly (spec: no --deep as the production strategy).
if [ -d "$FRAMEWORKS/Sparkle.framework" ]; then
    codesign --force --deep --sign - "$FRAMEWORKS/Sparkle.framework" 2>/dev/null \
        || echo "    (codesign unavailable, continuing unsigned)"
fi
codesign --force --sign - "$APP" 2>/dev/null || echo "    (codesign unavailable, continuing unsigned)"

echo "==> Registering with Launch Services"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" 2>/dev/null || true

echo
echo "==> Verifying bundle layout"
# ${VAR:+x} expands for ANY non-empty value (including "0"), so guard on the
# exact value: a dev bundle must not run the production feed/key checks.
if [ "$PRODUCTION" = "1" ]; then
    "$ROOT/Scripts/verify-bundle.sh" "$APP" --production
else
    "$ROOT/Scripts/verify-bundle.sh" "$APP"
fi

echo
echo "Built $APP"
echo
echo "Next:"
echo "  open '$APP'                     launch it"
echo "  Scripts/install.sh              copy to /Applications and link \`down\` into /usr/local/bin"
