#!/bin/bash
# Universal hosts must not ship host-only CLI/importer/framework binaries.
# Development and production updater smoke builds may intentionally be thin.
#
# Diagnostics go to stderr and the verdict is the exit status: callers branch on
# the status, so nothing here may print to stdout.
set -euo pipefail
APP="${1:?usage: verify-bundle-architectures.sh Downright.app}"

HOST="$APP/Contents/MacOS/Downright"
HOST_ARCHS="$(lipo -archs "$HOST" 2>/dev/null || true)"
if [ -z "$HOST_ARCHS" ]; then
    echo "cannot read host architectures: $HOST" >&2
    exit 1
fi

# `-L` so a nested Mach-O reachable only through a symlink is still checked:
# frameworks reach their binary through Versions/Current, and `-type f` alone
# never matches a symlink. A versioned framework is therefore scanned twice,
# which costs time and cannot change the verdict.
LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT
# The enumeration must be able to fail loudly. Inside a `while … done < <(find)`
# the exit status of `find` is discarded, so an unreadable subtree would leave
# the gate reporting success having checked nothing.
if ! find -L "$APP/Contents" -type f -print0 > "$LIST" 2>/dev/null; then
    echo "cannot enumerate bundle contents: $APP/Contents" >&2
    exit 1
fi

FAILED=0
while IFS= read -r -d '' nested; do
    file -b "$nested" 2>/dev/null | grep -q 'Mach-O' || continue
    for arch in $HOST_ARCHS; do
        if ! lipo "$nested" -verify_arch "$arch" >/dev/null 2>&1; then
            echo "missing $arch: $nested" >&2
            FAILED=1
        fi
    done
done < "$LIST"
exit "$FAILED"
