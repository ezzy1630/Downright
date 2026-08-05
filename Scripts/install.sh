#!/bin/bash
# Install Downright.app and the `down` CLI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${SCRATCH:-.build-main}"
SWIFTPM_APP="$ROOT/$SCRATCH/bundle/Downright.app"
XCODE_APP="$ROOT/.build-xcode/Build/Products/Release/Downright.app"
APP_SOURCE="${APP_SOURCE:-}"
APP_DEST="${APP_DEST:-/Applications/Downright.app}"
BIN_DEST="${BIN_DEST:-/usr/local/bin}"

if [ -z "$APP_SOURCE" ]; then
    if [ -d "$XCODE_APP/Contents/PlugIns/DownrightQL.appex" ] \
        && { [ ! -d "$SWIFTPM_APP" ] \
            || [ "$XCODE_APP/Contents/Info.plist" -nt "$SWIFTPM_APP/Contents/Info.plist" ]; }; then
        APP_SOURCE="$XCODE_APP"
    else
        APP_SOURCE="$SWIFTPM_APP"
    fi
fi

if [ ! -d "$APP_SOURCE" ]; then
    echo "Downright.app not built yet — running Scripts/bundle-app.sh"
    "$ROOT/Scripts/bundle-app.sh"
    APP_SOURCE="$SWIFTPM_APP"
fi

echo "==> Installing to $APP_DEST"
rm -rf "$APP_DEST"
cp -R "$APP_SOURCE" "$APP_DEST"

echo "==> Linking CLI into $BIN_DEST"
mkdir -p "$BIN_DEST"
DOWN_TARGET="$APP_DEST/Contents/MacOS/down"
if [ "$(readlink "$BIN_DEST/down" 2>/dev/null || true)" != "$DOWN_TARGET" ]; then
    ln -sf "$DOWN_TARGET" "$BIN_DEST/down" \
        || echo "    warning: could not update $BIN_DEST/down"
fi
# §3.4 calls the terminal launcher `md`; ship both names and let the user keep
# whichever fits their muscle memory.
if [ ! -e "$BIN_DEST/md" ]; then
    ln -sf "$DOWN_TARGET" "$BIN_DEST/md" \
        || echo "    warning: could not create $BIN_DEST/md"
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_DEST" 2>/dev/null || true

if command -v pluginkit >/dev/null 2>&1; then
    if [ -d "$APP_DEST/Contents/PlugIns/DownrightQL.appex" ]; then
        pluginkit -a "$APP_DEST/Contents/PlugIns/DownrightQL.appex" 2>/dev/null || true
        pluginkit -e use -i com.ezzyrappeport.downright.quicklook 2>/dev/null || true
    fi
    if [ -d "$APP_DEST/Contents/PlugIns/DownrightThumb.appex" ]; then
        pluginkit -a "$APP_DEST/Contents/PlugIns/DownrightThumb.appex" 2>/dev/null || true
        pluginkit -e use -i com.ezzyrappeport.downright.thumbnail 2>/dev/null || true
    fi
fi

if command -v qlmanage >/dev/null 2>&1; then
    qlmanage -r 2>/dev/null || true
    qlmanage -r cache 2>/dev/null || true
fi

echo
echo "Installed."
if [ -x "$BIN_DEST/down" ]; then
    echo "  down PLAN.md            open a file"
fi
if [ -x "$BIN_DEST/md" ]; then
    echo "  md PLAN.md              same thing"
fi
echo
echo "Quick Look: Downright preview and thumbnail extensions registered."
