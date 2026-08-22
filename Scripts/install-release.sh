#!/usr/bin/env bash
# Install the latest signed Downright release from GitHub.
#
# This is the remote installer used by https://downright.cc/install and by the
# npm launcher. It deliberately downloads the stable DMG and its published
# checksum, then verifies the mounted app before replacing an existing copy.
set -euo pipefail

RELEASE_BASE_URL="${DOWNRIGHT_RELEASE_BASE_URL:-https://github.com/ezzy1630/Downright/releases/latest/download}"
APP_DEST="${DOWNRIGHT_APP_DEST:-/Applications/Downright.app}"
BIN_DEST="${DOWNRIGHT_BIN_DIR:-$HOME/.local/bin}"
TEMP_ROOT="${TMPDIR:-/tmp}"
WORK_DIR="$(mktemp -d "$TEMP_ROOT/downright-release-install.XXXXXX")"
MOUNT_DIR="$WORK_DIR/mount"
DMG_PATH="$WORK_DIR/Downright.dmg"
CHECKSUM_PATH="$WORK_DIR/Downright.dmg.sha256"
STAGED_APP="$WORK_DIR/Downright.app"
BACKUP_APP="$WORK_DIR/previous.app"
DEVICE=""
# Set once the staged app is verified in place. Until then the backup is
# the only copy of the user's installed Downright, so every exit path must
# preserve or restore it rather than delete it.
INSTALL_FINALIZED=0

log() {
    printf '==> %s\n' "$*"
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local status=$?

    trap - EXIT INT TERM
    if [ -n "$DEVICE" ]; then
        hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true
    fi
    if [ "${INSTALL_FINALIZED:-0}" != "1" ] && [ -e "$BACKUP_APP" ]; then
        # The staged app never took over. Put the previous installation
        # back; if that is impossible, keep it on disk and say where it is
        # instead of deleting it with the work directory.
        if move_into_app_parent "$BACKUP_APP" "$APP_DEST" 2>/dev/null; then
            printf 'The previous Downright.app was restored.\n' >&2
        else
            printf 'warning: the previous app could not be restored automatically.\n' >&2
            printf 'It is preserved at: %s\n' "$BACKUP_APP" >&2
            WORK_DIR=""
        fi
    fi
    if [ -n "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

[ "$(uname -s)" = "Darwin" ] || fail "this installer only supports macOS"

for command_name in curl shasum hdiutil diskutil ditto codesign awk; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

DEST_PARENT="$(dirname "$APP_DEST")"
[ -d "$DEST_PARENT" ] || fail "application directory does not exist: $DEST_PARENT"

if pgrep -f "^${APP_DEST}/Contents/MacOS/Downright$" >/dev/null 2>&1; then
    fail "Downright is running; close it and run the installer again"
fi

mkdir -p "$MOUNT_DIR"
log "Downloading the latest Downright release"
curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 15 --max-time 600 \
    "$RELEASE_BASE_URL/Downright.dmg" -o "$DMG_PATH"
curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 15 --max-time 60 \
    "$RELEASE_BASE_URL/Downright.dmg.sha256" -o "$CHECKSUM_PATH"

EXPECTED_SHA="$(awk 'NF { print tolower($1); exit }' "$CHECKSUM_PATH")"
ACTUAL_SHA="$(shasum -a 256 "$DMG_PATH" | awk '{ print tolower($1) }')"
[ "${#EXPECTED_SHA}" -eq 64 ] || fail "release checksum file is malformed"
[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || fail "DMG checksum mismatch"
log "DMG checksum verified"

ATTACH_OUTPUT="$(diskutil image attach --mountOptions nobrowse --readOnly --mountPoint "$MOUNT_DIR" "$DMG_PATH")"
DEVICE="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '$1 ~ /^\/dev\/disk/ { print $1; exit }')"
[ -n "$DEVICE" ] || fail "could not determine mounted disk"

SOURCE_APP="$MOUNT_DIR/Downright.app"
[ -d "$SOURCE_APP" ] || fail "release DMG does not contain Downright.app"
codesign --verify --deep --strict "$SOURCE_APP" >/dev/null
log "Application signature verified"

ditto "$SOURCE_APP" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP" >/dev/null

move_into_app_parent() {
    if [ -w "$DEST_PARENT" ]; then
        mv "$@"
    else
        sudo mv "$@"
    fi
}

if [ -e "$APP_DEST" ]; then
    log "Replacing $APP_DEST"
    move_into_app_parent "$APP_DEST" "$BACKUP_APP"
fi

if ! move_into_app_parent "$STAGED_APP" "$APP_DEST"; then
    # cleanup() restores the backup on the way out; if even that fails it
    # preserves the backup and prints its location.
    fail "could not install the application in $APP_DEST"
fi

codesign --verify --deep --strict "$APP_DEST" >/dev/null
INSTALL_FINALIZED=1

if [ -e "$BACKUP_APP" ]; then
    if [ -w "$WORK_DIR" ]; then
        rm -rf "$BACKUP_APP"
    else
        sudo rm -rf "$BACKUP_APP"
    fi
fi

if [ "${DOWNRIGHT_SKIP_SYSTEM_INTEGRATION:-0}" != "1" ]; then
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    [ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP_DEST" >/dev/null 2>&1 || true

    if command -v pluginkit >/dev/null 2>&1; then
        for extension in DownrightQL.appex DownrightThumb.appex; do
            if [ -d "$APP_DEST/Contents/PlugIns/$extension" ]; then
                pluginkit -a "$APP_DEST/Contents/PlugIns/$extension" >/dev/null 2>&1 || true
            fi
        done
        pluginkit -e use -i com.ezzy.downright.quicklook >/dev/null 2>&1 || true
        pluginkit -e use -i com.ezzy.downright.thumbnail >/dev/null 2>&1 || true
    fi

    if command -v qlmanage >/dev/null 2>&1; then
        qlmanage -r >/dev/null 2>&1 || true
        qlmanage -r cache >/dev/null 2>&1 || true
    fi
fi

if [ -x "$APP_DEST/Contents/MacOS/down" ]; then
    link_cli() {
        local name="$1"
        local destination="$BIN_DEST/$name"
        if [ -e "$destination" ] && [ ! -L "$destination" ]; then
            printf 'warning: leaving existing non-symlink CLI at %s\n' "$destination" >&2
            return 0
        fi
        ln -sfn "$APP_DEST/Contents/MacOS/down" "$destination"
    }

    if mkdir -p "$BIN_DEST" && link_cli down && link_cli md; then
        log "CLI linked in $BIN_DEST"
    else
        printf 'warning: could not link the CLI in %s\n' "$BIN_DEST" >&2
    fi
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DEST/Contents/Info.plist" 2>/dev/null || printf 'latest')"
log "Installed Downright $VERSION in $APP_DEST"
printf 'Sparkle updates remain enabled in the installed app.\n'
