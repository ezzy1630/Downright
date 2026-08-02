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
BUNDLE_ID="com.unrulyagency.downright"
VERSION="1.0.0"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

OUT="$ROOT/$SCRATCH/bundle"
APP="$OUT/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --scratch-path "$SCRATCH" --product Downright
swift build -c "$CONFIGURATION" --scratch-path "$SCRATCH" --product down

BIN_DIR="$ROOT/$SCRATCH/$CONFIGURATION"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BIN_DIR/Downright" "$MACOS/$APP_NAME"
cp "$BIN_DIR/down" "$MACOS/down"

# SwiftPM resource bundles resolve through Bundle.main.resourceURL once they
# sit in Contents/Resources, which is exactly where Bundle.module looks first.
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
    <key>NSHumanReadableCopyright</key><string>MIT licensed.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Markdown Document</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>net.daringfireball.markdown</string>
                <string>com.unrulyagency.downright.markdown</string>
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
            <key>UTTypeIdentifier</key><string>com.unrulyagency.downright.markdown</string>
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

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
elif [ -x "$ROOT/Scripts/make-icon.sh" ]; then
    "$ROOT/Scripts/make-icon.sh" "$RESOURCES/AppIcon.icns" || true
fi

echo "==> Signing (ad-hoc)"
# Ad-hoc is enough to run locally and to keep the Quick Look extension host
# happy.  Real distribution needs a Developer ID plus notarisation — see
# Docs/RELEASE.md.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "    (codesign unavailable, continuing unsigned)"

echo "==> Registering with Launch Services"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" 2>/dev/null || true

echo
echo "Built $APP"
echo
echo "Next:"
echo "  open '$APP'                     launch it"
echo "  Scripts/install.sh              copy to /Applications and link \`down\` into /usr/local/bin"
