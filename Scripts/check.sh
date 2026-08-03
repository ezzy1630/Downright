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
TEST_LOG=/tmp/downright-test.log
if [ "${#TEST_FLAGS[@]}" -gt 0 ]; then
    swift test --no-parallel --scratch-path "$TEST_SCRATCH" "${TEST_FLAGS[@]}" > "$TEST_LOG" 2>&1
else
    swift test --no-parallel --scratch-path "$TEST_SCRATCH" > "$TEST_LOG" 2>&1
fi
TEST_STATUS=$?
grep -aE "Test run|✘|Suite .* (passed|failed)|error:|failed after" "$TEST_LOG" | tail -40

echo
echo "==> Sanity: the runner must actually have run something"
COUNT=$(awk '/^[✔✘] Test / && $0 !~ /^[✔✘] Test run / { count++ } END { print count + 0 }' "$TEST_LOG")
echo "    $COUNT tests executed"
[ "$COUNT" -gt 0 ] || { echo "    NO TESTS RAN — see the note at the top of this script"; exit 1; }
[ "$TEST_STATUS" -eq 0 ] || { echo "    TESTS FAILED — see $TEST_LOG"; exit "$TEST_STATUS"; }

echo
echo "==> Bench (debug, informational — exercises drbench and catches crashes)"
BENCH_LOG=/tmp/downright-bench.log
if ! swift run --scratch-path "$SCRATCH" drbench > "$BENCH_LOG" 2>&1; then
    echo "    FAILED"
    tail -30 "$BENCH_LOG"
    exit 1
fi
grep -aE "Typing response p95|End-to-end semantic convergence" "$BENCH_LOG" || true
echo "    ok"

# `RUN_DRBENCH=1 Scripts/check.sh` builds release and treats the budget as a
# gate, the way §12 intends it to be used in CI.  Debug numbers are not the
# product promise, so the default run above only checks that the tool runs.
if [ "${RUN_DRBENCH:-0}" = "1" ]; then
    echo "==> Bench (release, budgets enforced)"
    BENCH_RELEASE_LOG=/tmp/downright-bench-release.log
    if ! swift run -c release --scratch-path .build-bench drbench > "$BENCH_RELEASE_LOG" 2>&1; then
        echo "    FAILED — a performance budget was violated (or the build failed)"
        grep -aE "✗|❌|error:" "$BENCH_RELEASE_LOG" | sort -u | head -40
        exit 1
    fi
    grep -aE "Typing response p95|End-to-end semantic convergence" "$BENCH_RELEASE_LOG" || true
    echo "    ok"
fi

exit 0
