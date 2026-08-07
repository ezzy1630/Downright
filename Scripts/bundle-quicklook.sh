#!/bin/bash
# Build DownrightQL.appex and DownrightThumb.appex and embed them in the app.
#
# Docs/QUICKLOOK.md says an .appex needs Xcode.  It does not: an .appex is an
# ordinary bundle whose executable uses `NSExtensionMain` as its entry point
# instead of `main`.  SwiftPM can produce that executable, so this script keeps
# the Quick Look extensions on the same Command-Line-Tools-only path as
# Scripts/bundle-app.sh.
#
# The extension sources live in the main package as library targets so they are
# type-checked by `swift build`.  Linking them into an executable needs an
# *executable* target, so we generate a throwaway helper package in the scratch
# directory that depends on this one and re-uses the same source files.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-release}"
SCRATCH="${SCRATCH:-.build-main}"
APP="${APP:-$ROOT/$SCRATCH/bundle/Downright.app}"

[ -d "$APP" ] || { echo "No app bundle at $APP — run Scripts/bundle-app.sh first" >&2; exit 1; }

# Take both versions from the host rather than recomputing them: an extension
# has to carry its host's numbers, and Scripts/build-number.sh returns the epoch
# on a dirty tree, so two independent calls minutes apart never agree.
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
VERSION="$(plist_value CFBundleShortVersionString)"
BUILD="$(plist_value CFBundleVersion)"

HELPER="$ROOT/$SCRATCH/quicklook"

echo "==> Generating helper package in $HELPER"
rm -rf "$HELPER"
mkdir -p "$HELPER/Sources/DownrightQL" "$HELPER/Sources/DownrightThumb"

cat > "$HELPER/Package.swift" <<SWIFT
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DownrightQuickLook",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$ROOT")],
    targets: [
        .executableTarget(
            name: "DownrightQL",
            dependencies: [
                .product(name: "MarkdownCore", package: "Downright"),
                .product(name: "MarkdownRender", package: "Downright"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DownrightThumb",
            dependencies: [
                .product(name: "MarkdownCore", package: "Downright"),
                .product(name: "MarkdownRender", package: "Downright"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
SWIFT

# The extension host (`pluginkit`/`quicklookd`) launches the binary and expects
# NSExtensionMain to take over: it reads NSExtension from the Info.plist,
# instantiates NSExtensionPrincipalClass, and services the XPC connection.
# Xcode achieves this with `-e _NSExtensionMain`; calling it from top-level code
# is equivalent and needs no linker flags.
for target in DownrightQL DownrightThumb; do
    cp "$ROOT/Sources/$target"/*.swift "$HELPER/Sources/$target/"
    cat > "$HELPER/Sources/$target/main.swift" <<'SWIFT'
import Foundation

@_silgen_name("NSExtensionMain")
func downrightNSExtensionMain() -> Int32

exit(downrightNSExtensionMain())
SWIFT
done

echo "==> Building extensions ($CONFIGURATION)"
# `swift build` keeps only the last --product, so ask for them one at a time.
for target in DownrightQL DownrightThumb; do
    swift build --package-path "$HELPER" -c "$CONFIGURATION" \
        --scratch-path "$HELPER/.build" --product "$target"
done

HELPER_BIN="$HELPER/.build/$CONFIGURATION"

# App-sandbox is what Xcode's ENABLE_APP_SANDBOX gives these targets.  The
# read-only file entitlement covers the URL the Quick Look host hands over.
ENTITLEMENTS="$HELPER/extension.entitlements"
cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.files.user-selected.read-only</key><true/>
</dict>
</plist>
PLIST

PLUGINS="$APP/Contents/PlugIns"
rm -rf "$PLUGINS"
mkdir -p "$PLUGINS"

# The extensions are assembled as *flat* bundles — Info.plist, executable, and
# resources side by side at the bundle root — rather than the usual macOS
# Contents/MacOS layout.  Both layouts resolve resources correctly now that
# SwiftMath is vendored (Vendor/SwiftMath/PATCHES.md); flat is kept because it
# is the shape codesign seals with no special handling: the bundle root *is*
# the sealed root, so the resource bundles beside the executable are covered.
# Putting them at the root of a *deep* bundle instead fails verification with
# "unsealed contents present in the bundle root" — which is the constraint that
# made SwiftPM's generated `Bundle.module` unusable in a shipped .app in the
# first place.
#
# $(...) placeholders in the checked-in plists are Xcode build settings; this
# script substitutes the same values so the two build paths stay identical.
bundle_extension() {
    local name="$1" bundle_id="$2" src_plist="$3"
    local appex="$PLUGINS/$name.appex"

    echo "==> Assembling $name.appex"
    mkdir -p "$appex"
    cp "$HELPER_BIN/$name" "$appex/$name"

    sed -e "s|\$(EXECUTABLE_NAME)|$name|g" \
        -e "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|$bundle_id|g" \
        -e "s|\$(PRODUCT_MODULE_NAME)|$name|g" \
        -e "s|\$(MARKETING_VERSION)|$VERSION|g" \
        -e "s|\$(CURRENT_PROJECT_VERSION)|$BUILD|g" \
        "$src_plist" > "$appex/Info.plist"

    # Copy from the helper's own build products, not the app's, so the resources
    # match the code that was linked into this executable.
    for bundle in "$HELPER_BIN"/*.bundle; do
        [ -e "$bundle" ] || continue
        cp -R "$bundle" "$appex/"
    done
    cp "$ROOT/Resources/PrivacyInfo.xcprivacy" "$appex/" 2>/dev/null || true

    codesign --force --sign - --entitlements "$ENTITLEMENTS" \
        --identifier "$bundle_id" "$appex" 2>/dev/null \
        || echo "    (codesign unavailable, continuing unsigned)"

    codesign --verify "$appex" 2>/dev/null \
        || echo "    WARNING: $name.appex failed signature verification"
}

bundle_extension DownrightQL com.ezzy.downright.quicklook "$ROOT/Config/DownrightQL-Info.plist"
bundle_extension DownrightThumb com.ezzy.downright.thumbnail "$ROOT/Config/DownrightThumb-Info.plist"

# Embedding new code invalidates the host's signature, so re-sign it.  Nested
# code (Sparkle, the extensions) is already signed and is left alone.
echo "==> Re-signing $APP"
codesign --force --sign - "$APP" 2>/dev/null \
    || echo "    (codesign unavailable, continuing unsigned)"

# The layout above is load-bearing, not cosmetic: an extension whose resource
# bundles are not where its resolvers look previews math as raw LaTeX at best.
# Verify here rather than in bundle-app.sh, which runs before Contents/PlugIns
# exists.
echo
echo "==> Verifying bundle layout"
"$ROOT/Scripts/verify-bundle.sh" "$APP"

echo
echo "Embedded:"
echo "  $PLUGINS/DownrightQL.appex"
echo "  $PLUGINS/DownrightThumb.appex"
echo
echo "Next: Scripts/install.sh  (registers and enables both extensions)"
