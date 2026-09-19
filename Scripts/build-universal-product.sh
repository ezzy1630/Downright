#!/bin/bash
# Build one SwiftPM product for a set of architectures and merge the slices.
#
# SwiftPM's own multi-architecture build (`swift build --arch a --arch b`) is
# deliberately not used. It works for an executable on some toolchains, but on
# the release toolchain it fails while generating a TBD for a fat *dynamic
# library*:
#
#   error: input '.../libDownrightSpotlightImporter.dylib' is not a dynamic library
#
# which took a signed release down after the check suite had already passed.
# The two toolchains also disagree about where a multi-arch build lands
# (`out/Products` vs `apple/Products`). Building each slice in its own scratch
# path and merging them with lipo produces the same artifact through a path both
# agree on, and keeps the failure surface to commands whose behaviour is stable.
#
# usage: build-universal-product.sh PRODUCT ARTIFACT CONFIGURATION SCRATCH_BASE OUTPUT ARCH...
set -euo pipefail
PRODUCT="${1:?product}"
ARTIFACT="${2:?artifact file name}"
CONFIGURATION="${3:?configuration}"
SCRATCH_BASE="${4:?scratch base}"
OUTPUT="${5:?output path}"
shift 5
[ "$#" -gt 0 ] || {
    echo "build-universal-product: no architectures given" >&2
    exit 1
}

SLICES=()
for arch in "$@"; do
    scratch="${SCRATCH_BASE}-${arch}"
    # Build output goes to stderr so a caller may capture this script's stdout.
    swift build --arch "$arch" -c "$CONFIGURATION" \
        --scratch-path "$scratch" --product "$PRODUCT" >&2
    # SwiftPM places products directly under the scratch directory on some
    # toolchains and under a target-triple directory on others. Ask for the
    # active binary directory rather than assuming either layout.
    bin="$(swift build --arch "$arch" -c "$CONFIGURATION" \
        --scratch-path "$scratch" --product "$PRODUCT" --show-bin-path)"
    slice="$bin/$ARTIFACT"
    [ -f "$slice" ] || {
        echo "build-universal-product: SwiftPM did not produce $slice" >&2
        exit 1
    }
    SLICES+=("$slice")
done

mkdir -p "$(dirname "$OUTPUT")"
if [ "${#SLICES[@]}" -eq 1 ]; then
    # `cp` keeps the slice's own signature, so nothing to re-seal.
    cp "${SLICES[0]}" "$OUTPUT"
else
    lipo -create "${SLICES[@]}" -output "$OUTPUT"
    # lipo does not carry code signatures across, and every slice SwiftPM
    # produced was ad-hoc signed. Without this the merged binary is "not signed
    # at all", which fails the enclosing bundle's seal. The release pipeline
    # replaces this with the Developer ID signature later.
    #
    # codesign's own stderr is deliberately not discarded. In the acceptance
    # lane this is the only signature the embedded CLI ever gets, so a failure
    # here must say why rather than abort bare on `set -e` — an unexplained
    # unsigned binary is the failure class this script exists to remove.
    if ! codesign --force --sign - "$OUTPUT"; then
        echo "build-universal-product: could not re-seal $OUTPUT" >&2
        exit 1
    fi
fi
