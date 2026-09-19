#!/bin/bash
# Universal hosts must not ship host-only CLI/importer/framework binaries.
# Development and production updater smoke builds may intentionally be thin.
set -euo pipefail
APP="${1:?usage: verify-bundle-architectures.sh Downright.app}"
HOST_ARCHS="$(lipo -archs "$APP/Contents/MacOS/Downright")"
[ -n "$HOST_ARCHS" ] || exit 1
FAILED=0
while IFS= read -r -d '' nested; do
    if file -b "$nested" | grep -q 'Mach-O'; then
        for arch in $HOST_ARCHS; do
            if ! lipo "$nested" -verify_arch "$arch" >/dev/null 2>&1; then
                echo "missing $arch: $nested" >&2
                FAILED=1
            fi
        done
    fi
done < <(find "$APP/Contents" -type f -print0)
exit "$FAILED"
