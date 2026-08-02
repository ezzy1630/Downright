#!/bin/bash
# Build everything and run every test suite.
#
# The `-F` flag is load-bearing on a machine with only the Command Line Tools.
# SwiftPM generates the test runner with `#if canImport(Testing)` around the
# swift-testing entry point, and swift-testing ships with the CLT *outside*
# SwiftPM's default framework search path.  Without the flag that `canImport`
# is false, the branch compiles out, and `swift test` exits 0 having run
# nothing at all — the worst possible failure mode.  Always run tests through
# this script, or pass the flag yourself.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SCRATCH="${SCRATCH:-.build-main}"
# Tests need an extra `-F` flag, and alternating flag sets in one scratch
# path makes SwiftPM rebuild the world on every switch.  Keep them apart.
TEST_SCRATCH="${TEST_SCRATCH:-.build-test}"

CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
TEST_FLAGS=()
SELECTED_DEVELOPER="$(xcode-select -p 2>/dev/null || true)"
if [[ "$SELECTED_DEVELOPER" == /Library/Developer/CommandLineTools* ]] \
    && [ -d "$CLT_FRAMEWORKS/Testing.framework" ]; then
    TEST_FLAGS=(-Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS")
fi

echo "==> Build"
if ! swift build --scratch-path "$SCRATCH" > /tmp/downright-build.log 2>&1; then
    echo "    FAILED"
    grep "error:" /tmp/downright-build.log | sort -u | head -40
    exit 1
fi
echo "    ok"

echo "==> Tests"
swift test --scratch-path "$TEST_SCRATCH" "${TEST_FLAGS[@]}" 2>&1 \
    | grep -E "Test run|✘|Suite .* (passed|failed)|error:|failed after" \
    | tail -40

echo
echo "==> Sanity: the runner must actually have run something"
COUNT=$(swift test --scratch-path "$TEST_SCRATCH" "${TEST_FLAGS[@]}" 2>&1 | grep -cE "^✔ Test |^✘ Test ")
echo "    $COUNT tests executed"
[ "$COUNT" -gt 0 ] || { echo "    NO TESTS RAN — see the note at the top of this script"; exit 1; }
