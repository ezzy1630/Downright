#!/bin/bash
# Checksummed tooling, installed only in a task/cache-owned directory.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${1:-$ROOT/.build-tools}"
VERSION=1.7.12
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) PLATFORM=darwin_arm64; SHA=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f ;;
    Darwin-x86_64) PLATFORM=darwin_amd64; SHA=5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644 ;;
    Linux-x86_64) PLATFORM=linux_amd64; SHA=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 ;;
    Linux-aarch64) PLATFORM=linux_arm64; SHA=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6 ;;
    *) echo "actionlint: unsupported platform" >&2; exit 1 ;;
esac
mkdir -p "$DESTINATION"
TEMPORARY="$(mktemp -d)"
trap 'rm -rf "$TEMPORARY"' EXIT
curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 15 --max-time 180 "https://github.com/rhysd/actionlint/releases/download/v$VERSION/actionlint_${VERSION}_${PLATFORM}.tar.gz" -o "$TEMPORARY/actionlint.tar.gz"
echo "$SHA  $TEMPORARY/actionlint.tar.gz" | shasum -a 256 -c -
tar -xzf "$TEMPORARY/actionlint.tar.gz" -C "$TEMPORARY" actionlint
cp "$TEMPORARY/actionlint" "$DESTINATION/actionlint"
chmod +x "$DESTINATION/actionlint"
