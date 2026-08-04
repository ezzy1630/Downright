#!/bin/bash
# Install Downright.app and the `down` CLI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${SCRATCH:-.build-main}"
APP_SOURCE="$ROOT/$SCRATCH/bundle/Downright.app"
APP_DEST="${APP_DEST:-/Applications/Downright.app}"
BIN_DEST="${BIN_DEST:-/usr/local/bin}"

if [ ! -d "$APP_SOURCE" ]; then
    echo "Downright.app not built yet — running Scripts/bundle-app.sh"
    "$ROOT/Scripts/bundle-app.sh"
fi

echo "==> Installing to $APP_DEST"
rm -rf "$APP_DEST"
cp -R "$APP_SOURCE" "$APP_DEST"

echo "==> Linking CLI into $BIN_DEST"
mkdir -p "$BIN_DEST"
ln -sf "$APP_DEST/Contents/MacOS/down" "$BIN_DEST/down"
# §3.4 calls the terminal launcher `md`; ship both names and let the user keep
# whichever fits their muscle memory.
if [ ! -e "$BIN_DEST/md" ]; then
    ln -sf "$APP_DEST/Contents/MacOS/down" "$BIN_DEST/md"
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
echo "  down PLAN.md            open a file"
echo "  md PLAN.md              same thing"
echo
echo "Quick Look: Downright preview and thumbnail extensions registered."
