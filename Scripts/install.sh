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

if [ ! -x "$APP_SOURCE/Contents/MacOS/Downright" ]; then
    echo "error: candidate has no Downright executable: $APP_SOURCE" >&2
    exit 1
fi
"$ROOT/Scripts/verify-bundle.sh" "$APP_SOURCE"

echo "==> Installing to $APP_DEST"
DEST_PARENT="$(dirname "$APP_DEST")"
STAGE_ROOT="$(mktemp -d "$DEST_PARENT/.downright-install.XXXXXX")"
STAGED_APP="$STAGE_ROOT/Downright.app"
BACKUP_APP="$STAGE_ROOT/previous.app"
trap 'rm -rf "$STAGE_ROOT"' EXIT
cp -R "$APP_SOURCE" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

# A running old process can keep Finder extensions and window state pinned to
# deleted code. Stop only this exact installed bundle before the atomic swap.
pkill -f "^$APP_DEST/Contents/MacOS/Downright$" 2>/dev/null || true
if [ -d "$APP_DEST" ]; then mv "$APP_DEST" "$BACKUP_APP"; fi
if ! mv "$STAGED_APP" "$APP_DEST"; then
    if [ -d "$BACKUP_APP" ]; then mv "$BACKUP_APP" "$APP_DEST"; fi
    exit 1
fi
rm -rf "$BACKUP_APP"

echo "==> Linking CLI into $BIN_DEST"
mkdir -p "$BIN_DEST"
DOWN_TARGET="$APP_DEST/Contents/MacOS/down"
if [ "$(readlink "$BIN_DEST/down" 2>/dev/null || true)" != "$DOWN_TARGET" ]; then
    ln -sf "$DOWN_TARGET" "$BIN_DEST/down" \
        || echo "    warning: could not update $BIN_DEST/down"
fi
# §3.4 calls the terminal launcher `md`; ship both names and let the user keep
# whichever fits their muscle memory.
if ! command -v md >/dev/null 2>&1; then
    ln -sf "$DOWN_TARGET" "$BIN_DEST/md" \
        || echo "    warning: could not create $BIN_DEST/md"
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_DEST" 2>/dev/null || true

if command -v pluginkit >/dev/null 2>&1; then
    if [ -d "$APP_DEST/Contents/PlugIns/DownrightQL.appex" ]; then
        pluginkit -a "$APP_DEST/Contents/PlugIns/DownrightQL.appex" 2>/dev/null || true
        pluginkit -e use -i com.ezzy.downright.quicklook 2>/dev/null || true
    fi
    if [ -d "$APP_DEST/Contents/PlugIns/DownrightThumb.appex" ]; then
        pluginkit -a "$APP_DEST/Contents/PlugIns/DownrightThumb.appex" 2>/dev/null || true
        pluginkit -e use -i com.ezzy.downright.thumbnail 2>/dev/null || true
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
if [ -d "$APP_DEST/Contents/PlugIns/DownrightQL.appex" ] \
    && [ -d "$APP_DEST/Contents/PlugIns/DownrightThumb.appex" ]; then
    echo "Quick Look: Downright preview and thumbnail extensions registered."
else
    echo "Quick Look: extensions are not present in this bundle."
fi
