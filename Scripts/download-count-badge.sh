#!/bin/bash
# Render the DMG request count as an SVG served directly from GitHub Releases.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: Scripts/download-count-badge.sh COUNT" >&2
    exit 2
fi
TOTAL="$1"
case "$TOTAL" in
    ''|*[!0-9]*) echo "count must be a non-negative integer" >&2; exit 2 ;;
esac

# Fixed-width digits keep the badge legible without font-measurement tooling.
VALUE_WIDTH=$((${#TOTAL} * 7 + 20))
WIDTH=$((97 + VALUE_WIDTH))
VALUE_X=$((97 + VALUE_WIDTH / 2))
cat <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="$WIDTH" height="20" role="img" aria-label="total downloads: $TOTAL">
  <title>total downloads: $TOTAL</title>
  <clipPath id="r"><rect width="$WIDTH" height="20" rx="3"/></clipPath>
  <g clip-path="url(#r)">
    <path fill="#555" d="M0 0h97v20H0z"/>
    <path fill="#307afe" d="M97 0h${VALUE_WIDTH}v20H97z"/>
  </g>
  <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11">
    <text x="48.5" y="14">total downloads</text>
    <text x="$VALUE_X" y="14" font-family="DejaVu Sans Mono,monospace">$TOTAL</text>
  </g>
</svg>
SVG
