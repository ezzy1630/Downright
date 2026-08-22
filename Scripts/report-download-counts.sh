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
ALL=0

# One asset-naming contract for every mode: a versioned artifact may carry the
# "-<build>-<sha>" release suffix, and a milestone-style bare version counts
# the same whether the report covers one release or all of them.  These are
# handed to jq through --arg, which takes the value raw — single backslashes.
VERSIONED_DMG_PATTERN='^Downright-[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+-[0-9a-f]+)?\.dmg$'
UPDATE_ZIP_PATTERN='^Downright-[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+-[0-9a-f]+)?\.zip$'

usage() {
    echo "usage: Scripts/report-download-counts.sh [--release latest|TAG] [--all] [--json]" >&2
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
        --all)
            ALL=1
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

# Temporary files removed on exit. A single handler because the pagination
# loop below re-points nothing: every consumer appends here.
CLEANUP_FILES=()
cleanup() {
    local file
    for file in "${CLEANUP_FILES[@]:-}"; do
        [ -n "$file" ] && rm -f "$file"
    done
}
trap cleanup EXIT

CURL_ARGS=(-fsSL -H 'Accept: application/vnd.github+json')
if [ -n "${GITHUB_TOKEN:-}" ]; then
    # The token goes through a curl config file rather than the command
    # line: arguments are world-readable in `ps` output for as long as the
    # request runs, and this report can run on developer machines.
    CURL_CONFIG="$(mktemp)"
    chmod 600 "$CURL_CONFIG"
    CLEANUP_FILES+=("$CURL_CONFIG")
    printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" > "$CURL_CONFIG"
    CURL_ARGS+=(--config "$CURL_CONFIG")
fi

REMOTE="$(git -C "$ROOT" config --get remote.origin.url || true)"
REPOSITORY="$(printf '%s' "$REMOTE" | sed -E 's#^https://github.com/##; s#^git@github.com:##; s#\.git$##')"
case "$REPOSITORY" in
    */*) ;;
    *) echo "could not derive a GitHub repository from origin" >&2; exit 1 ;;
esac

if [ "$ALL" = "1" ]; then
    # The releases endpoint defaults to 30 results. Keep following pages so
    # the README counter remains cumulative as the project grows.
    RELEASES_FILE="$(mktemp)"
    CLEANUP_FILES+=("$RELEASES_FILE")
    PAGE=1
    while :; do
        RESPONSE="$(curl "${CURL_ARGS[@]}" \
            "https://api.github.com/repos/$REPOSITORY/releases?per_page=100&page=$PAGE")"
        COUNT="$(printf '%s' "$RESPONSE" | jq 'length')"
        [ "$COUNT" -gt 0 ] || break
        printf '%s\n' "$RESPONSE" >> "$RELEASES_FILE"
        [ "$COUNT" -lt 100 ] && break
        PAGE=$((PAGE + 1))
    done

    RELEASES="$(jq -s 'add // []' "$RELEASES_FILE")"
    RELEASE_COUNT="$(printf '%s' "$RELEASES" | jq 'length')"
    STABLE_DMGS="$(printf '%s' "$RELEASES" | jq -r '[.[] | .assets[]? | select(.name == "Downright.dmg") | .download_count] | add // 0')"
    VERSIONED_DMGS="$(printf '%s' "$RELEASES" | jq -r --arg pattern "$VERSIONED_DMG_PATTERN" '[.[] | .assets[]? | select(.name | test($pattern)) | .download_count] | add // 0')"
    ACQUISITION_DMGS=$((STABLE_DMGS + VERSIONED_DMGS))
    UPDATE_ZIPS="$(printf '%s' "$RELEASES" | jq -r --arg pattern "$UPDATE_ZIP_PATTERN" '[.[] | .assets[]? | select(.name | test($pattern)) | .download_count] | add // 0')"

    if [ "$JSON" = "1" ]; then
        printf '%s' "$RELEASES" | jq --arg repository "$REPOSITORY" \
            --argjson stable_dmg_downloads "$STABLE_DMGS" \
            --argjson versioned_dmg_downloads "$VERSIONED_DMGS" \
            --argjson acquisition_downloads "$ACQUISITION_DMGS" \
            --argjson sparkle_update_downloads "$UPDATE_ZIPS" \
            '{repository: $repository, release: "all", release_count: length, downloads: {acquisition_dmgs: $acquisition_downloads, stable_dmg: $stable_dmg_downloads, versioned_dmgs: $versioned_dmg_downloads, sparkle_update_zips: $sparkle_update_downloads}, assets: [.[] | .tag_name as $release | .assets[]? | {release: $release, name, download_count, browser_download_url}]}'
        exit 0
    fi

    echo "Repository: $REPOSITORY"
    echo "Releases:   $RELEASE_COUNT"
    echo "Acquisition downloads (all DMGs): $ACQUISITION_DMGS"
    echo "  Stable DMGs:                     $STABLE_DMGS"
    echo "  Versioned DMGs:                  $VERSIONED_DMGS"
    echo "Update downloads (Sparkle ZIPs):   $UPDATE_ZIPS"
    exit 0
fi

if [ "$RELEASE" = "latest" ]; then
    API_URL="https://api.github.com/repos/$REPOSITORY/releases/latest"
else
    API_URL="https://api.github.com/repos/$REPOSITORY/releases/tags/$RELEASE"
fi

RESPONSE="$(curl "${CURL_ARGS[@]}" "$API_URL")"
TAG="$(printf '%s' "$RESPONSE" | jq -r '.tag_name // empty')"
[ -n "$TAG" ] || { echo "release not found: $RELEASE" >&2; exit 1; }

STABLE_DMG="$(printf '%s' "$RESPONSE" | jq -r '[.assets[] | select(.name == "Downright.dmg") | .download_count] | add // 0')"
VERSIONED_DMGS="$(printf '%s' "$RESPONSE" | jq -r --arg pattern "$VERSIONED_DMG_PATTERN" '[.assets[] | select(.name | test($pattern)) | .download_count] | add // 0')"
ACQUISITION_DMGS=$((STABLE_DMG + VERSIONED_DMGS))
UPDATE_ZIPS="$(printf '%s' "$RESPONSE" | jq -r --arg pattern "$UPDATE_ZIP_PATTERN" '[.assets[] | select(.name | test($pattern)) | .download_count] | add // 0')"

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
