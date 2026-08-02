#!/bin/bash
# Render the app icon and convert it to .icns.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/Resources/AppIcon.icns}"
WORK="$(mktemp -d)/Downright.iconset"
trap 'rm -rf "$(dirname "$WORK")"' EXIT

swift "$ROOT/Scripts/make-icon.swift" "$WORK" >/dev/null
mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$WORK" -o "$OUT"
echo "wrote $OUT"
