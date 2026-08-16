#!/bin/bash
# Report GitHub Release asset download counts for Downright.
#
# GitHub counts asset downloads, not unique people. DMGs represent acquisition
# requests, including direct downloads and Homebrew cask installs. Sparkle ZIPs
# represent updates and must not be added to the acquisition total.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE="latest"
JSON=0

usage() {
    echo "usage: Scripts/report-download-counts.sh [--release latest|TAG] [--json]" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --release)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            RELEASE="$2"
            shift 2
            ;;
        --json)
            JSON=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

REMOTE="$(git -C "$ROOT" config --get remote.origin.url || true)"
REPOSITORY="$(printf '%s' "$REMOTE" | sed -E 's#^https://github.com/##; s#^git@github.com:##; s#\.git$##')"
case "$REPOSITORY" in
    */*) ;;
    *) echo "could not derive a GitHub repository from origin" >&2; exit 1 ;;
esac

if [ "$RELEASE" = "latest" ]; then
    API_URL="https://api.github.com/repos/$REPOSITORY/releases/latest"
else
    API_URL="https://api.github.com/repos/$REPOSITORY/releases/tags/$RELEASE"
fi

RESPONSE="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$API_URL")"
TAG="$(printf '%s' "$RESPONSE" | jq -r '.tag_name // empty')"
[ -n "$TAG" ] || { echo "release not found: $RELEASE" >&2; exit 1; }

STABLE_DMG="$(printf '%s' "$RESPONSE" | jq -r '[.assets[] | select(.name == "Downright.dmg") | .download_count] | add // 0')"
VERSIONED_DMGS="$(printf '%s' "$RESPONSE" | jq -r '[.assets[] | select(.name | test("^Downright-[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+-[0-9a-f]+\\.dmg$")) | .download_count] | add // 0')"
ACQUISITION_DMGS=$((STABLE_DMG + VERSIONED_DMGS))
UPDATE_ZIPS="$(printf '%s' "$RESPONSE" | jq -r '[.assets[] | select(.name | test("^Downright-[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9]+-[0-9a-f]+)?\\.zip$")) | .download_count] | add // 0')"

if [ "$JSON" = "1" ]; then
    printf '%s' "$RESPONSE" | jq --arg repository "$REPOSITORY" \
        --argjson stable_dmg_downloads "$STABLE_DMG" \
        --argjson versioned_dmg_downloads "$VERSIONED_DMGS" \
        --argjson acquisition_downloads "$ACQUISITION_DMGS" \
        --argjson sparkle_update_downloads "$UPDATE_ZIPS" \
        '{repository: $repository, release: .tag_name, downloads: {acquisition_dmgs: $acquisition_downloads, stable_dmg: $stable_dmg_downloads, versioned_dmgs: $versioned_dmg_downloads, sparkle_update_zips: $sparkle_update_downloads}, assets: [.assets[] | {name, download_count, browser_download_url}]}'
    exit 0
fi

echo "Repository: $REPOSITORY"
echo "Release:    $TAG"
printf '%-48s %12s\n' "Asset" "Downloads"
printf '%-48s %12s\n' "-----------------------------------------------" "------------"
printf '%s\n' "$RESPONSE" | jq -r '.assets[] | "\(.name)\t\(.download_count)"' | while IFS=$'\t' read -r name count; do
    printf '%-48s %12s\n' "$name" "$count"
done

echo
echo "Acquisition downloads (all DMGs): $ACQUISITION_DMGS"
echo "  Stable DMG:                      $STABLE_DMG"
echo "  Versioned DMGs:                  $VERSIONED_DMGS"
echo "Update downloads (Sparkle ZIPs):    $UPDATE_ZIPS"
