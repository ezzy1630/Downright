#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${1:-${RUNNER_TEMP:-$ROOT/.build-tools}/xcodegen}"
TEMPORARY="$(mktemp -d)"
trap 'rm -rf "$TEMPORARY"' EXIT
curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 15 --max-time 180 https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip -o "$TEMPORARY/xcodegen.zip"
echo "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806  $TEMPORARY/xcodegen.zip" | shasum -a 256 -c -
unzip -q "$TEMPORARY/xcodegen.zip" -d "$TEMPORARY"
# SettingPresets are resolved relative to the executable; keep bin and share.
mkdir -p "$DESTINATION/bin" "$DESTINATION/share"
# Replace only XcodeGen-owned files; a caller's prefix may contain other tools.
rm -rf "$DESTINATION/share/xcodegen"
cp "$TEMPORARY/xcodegen/bin/xcodegen" "$DESTINATION/bin/xcodegen"
cp -R "$TEMPORARY/xcodegen/share/xcodegen" "$DESTINATION/share/xcodegen"
if [ -n "${GITHUB_PATH:-}" ]; then echo "$DESTINATION/bin" >> "$GITHUB_PATH"; fi
"$DESTINATION/bin/xcodegen" --version
