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

LIST="$(mktemp)"
ERRORS="$(mktemp)"
trap 'rm -f "$LIST" "$ERRORS"' EXIT

# Symlinks are matched (`-type l`) but not descended through: a nested binary
# reachable only as a symlink — a framework's Versions/Current/… — must still be
# verified, while following symlinked *directories* would let the gate wander
# outside the bundle (making the verdict depend on external state) or spin on a
# symlink loop. `file` and `lipo` both dereference, so a symlinked Mach-O is
# still read, and a dangling one is simply not Mach-O.
#
# The enumeration must also be able to fail loudly. Inside a
# `while … done < <(find)` the exit status of `find` is discarded, so an
# unreadable subtree would leave the gate reporting success having checked
# nothing. Its stderr is kept out of the NUL-separated list but surfaced, never
# swallowed.
if ! find "$APP/Contents" \( -type f -o -type l \) -print0 > "$LIST" 2> "$ERRORS"; then
    echo "cannot enumerate bundle contents: $APP/Contents" >&2
    cat "$ERRORS" >&2
    exit 1
fi
if [ -s "$ERRORS" ]; then
    echo "errors while enumerating $APP/Contents:" >&2
    cat "$ERRORS" >&2
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
