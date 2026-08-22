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
# The backup of the outgoing app deliberately lives OUTSIDE the staging tree
# the exit trap deletes. Between "old app moved aside" and "new app in
# place", the backup is the only copy of the user's installed Downright; an
# interruption there used to destroy it along with the staging directory and
# leave /Applications empty.
BACKUP_ROOT="$(mktemp -d "$DEST_PARENT/.downright-previous.XXXXXX")"
BACKUP_APP="$BACKUP_ROOT/Downright.app"
SWAPPED_IN=0

finish() {
    local status=$?
    trap - EXIT INT TERM
    rm -rf "$STAGE_ROOT"
    if [ "$SWAPPED_IN" != "1" ] && [ -d "$BACKUP_APP" ]; then
        if mv "$BACKUP_APP" "$APP_DEST" 2>/dev/null; then
            rm -rf "$BACKUP_ROOT"
            echo "The previous Downright.app was restored." >&2
        else
            # Never delete the backup when the restore failed: it is the
            # only copy left. Say where it is instead.
            echo "error: install did not finish and the previous app could not be restored." >&2
            echo "       It is preserved at: $BACKUP_APP" >&2
            BACKUP_ROOT=""
        fi
    fi
    if [ -n "$BACKUP_ROOT" ]; then
        rm -rf "$BACKUP_ROOT"
    fi
    exit "$status"
}
trap finish EXIT
trap 'exit 130' INT TERM
cp -R "$APP_SOURCE" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

# A running app would be killed silently here, losing unsaved edits; the
# public installer refuses instead, so do the same and let the user close
# the document they have open.
if pgrep -f "^$APP_DEST/Contents/MacOS/Downright$" >/dev/null 2>&1; then
    echo "error: Downright is running; close it and run this installer again." >&2
    exit 1
fi
if [ -d "$APP_DEST" ]; then mv "$APP_DEST" "$BACKUP_APP"; fi
if ! mv "$STAGED_APP" "$APP_DEST"; then
    if [ -d "$BACKUP_APP" ]; then
        mv "$BACKUP_APP" "$APP_DEST" \
            || { echo "error: could not restore the previous app; it is preserved at $BACKUP_APP" >&2; false; }
    fi
    exit 1
fi
SWAPPED_IN=1
rm -rf "$BACKUP_ROOT"

echo "==> Linking CLI into $BIN_DEST"
if ! mkdir -p "$BIN_DEST" 2>/dev/null; then
    # Not fatal: the app itself is installed. The default destination needs
    # write access to /usr/local; BIN_DEST points somewhere writable when
    # that is not available.
    echo "    warning: could not create $BIN_DEST — skipping the CLI links" >&2
else
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
