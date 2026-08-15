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

# Logs are named after the scratch path, not fixed under /tmp.  Two runs with
# different SCRATCH values are a deliberately supported thing (CI uses its own,
# and running a second check while one is in flight is normal), but with fixed
# names they silently overwrote each other's logs — so a failure reported the
# *other* run's errors, or none at all.
LOG_TAG="$(printf '%s' "$SCRATCH" | tr -c 'A-Za-z0-9._-' '-')"
LOG_DIR="${TMPDIR:-/tmp}"

CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
TEST_FLAGS=()
SELECTED_DEVELOPER="$(xcode-select -p 2>/dev/null || true)"
if [[ "$SELECTED_DEVELOPER" == /Library/Developer/CommandLineTools* ]] \
    && [ -d "$CLT_FRAMEWORKS/Testing.framework" ]; then
    TEST_FLAGS=(-Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS")
fi

echo "==> Build"
if ! swift build --scratch-path "$SCRATCH" > "$LOG_DIR/downright-build-$LOG_TAG.log" 2>&1; then
    echo "    FAILED"
    grep "error:" "$LOG_DIR/downright-build-$LOG_TAG.log" | sort -u | head -40
    exit 1
fi
echo "    ok"

echo "==> Tests"
TEST_LOG="$LOG_DIR/downright-test-$LOG_TAG.log"
if [ "${#TEST_FLAGS[@]}" -gt 0 ]; then
    swift test --no-parallel --scratch-path "$TEST_SCRATCH" "${TEST_FLAGS[@]}" > "$TEST_LOG" 2>&1
else
    swift test --no-parallel --scratch-path "$TEST_SCRATCH" > "$TEST_LOG" 2>&1
fi
TEST_STATUS=$?
grep -aE "Test run|✘|Suite .* (passed|failed)|error:|failed after" "$TEST_LOG" | tail -40
if [ "$TEST_STATUS" -ne 0 ]; then
    echo
    echo "    Failure details"
    # Suite summaries can push the actual assertion diagnostics out of the
    # tail above once the test graph is large. Always preserve the actionable
    # lines in CI output; the runner's temporary full log disappears with it.
    grep -aE "✘|Expectation failed|Issue recorded|error:|failed after" "$TEST_LOG" \
        | head -120
fi

echo
echo "==> Version consistency (single source: Config/version.env)"
"$ROOT/Scripts/sync-versions.sh"

echo "==> Sparkle is linked only by the host app"
SPARKLE_IMPORTS="$(grep -rln 'import Sparkle' Sources --include='*.swift' || true)"
if [ -z "$SPARKLE_IMPORTS" ]; then
    echo "    FAIL: no source file imports Sparkle — the updater was not wired up"
    exit 1
fi
for file in $SPARKLE_IMPORTS; do
    case "$file" in
        Sources/DownrightApp/Updater/*) : ;;  # the engine boundary, as designed
        Sources/DownrightApp/*) : ;;
        *) echo "    FAIL: Sparkle imported outside the host app: $file"; exit 1 ;;
    esac
done
echo "    ok"

echo
echo "==> Theme contrast"
python3 "$ROOT/Scripts/check-contrast.py"

echo
echo "==> Sanity: the runner must actually have run something"
# macOS ships BSD awk, which only matches multibyte characters (✔ ✘) under a
# UTF-8 locale — with the default C locale the bracket expression never
# matches and every correctly-run suite counts as "nothing ran".  Pin the
# locale so the gate measures tests, not bytes.
COUNT=$(LC_ALL=en_US.UTF-8 awk '/^[✔✘] Test / && $0 !~ /^[✔✘] Test run / { count++ } END { print count + 0 }' "$TEST_LOG")
# A missing or unreadable log leaves COUNT empty, and an empty COUNT must read
# as "nothing ran", never as "the arithmetic test was malformed, carry on".
case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac
echo "    $COUNT tests executed"
if [ "$COUNT" -eq 0 ]; then
    echo "    NO TESTS RAN — see the note at the top of this script"
    exit 1
fi

# Known issues are deliberate environment boundaries, not a second success
# path. Keep their inventory explicit so a test cannot quietly become a
# permanent suppression (or disappear from the gate) while the test count still
# looks healthy. The two current sites are the headless TextKit viewport hit
# test and the raster smoke test; an activated-app lane exercises both without
# this exception.
KNOWN_ISSUE_SITES=$(rg -n "withKnownIssue\\(" Tests | wc -l | tr -d ' ')
EXPECTED_KNOWN_ISSUES=2
echo "    $KNOWN_ISSUE_SITES deliberate known-issue sites"
if [ "$KNOWN_ISSUE_SITES" -ne "$EXPECTED_KNOWN_ISSUES" ]; then
    echo "    KNOWN-ISSUE GATE FAILED — expected exactly $EXPECTED_KNOWN_ISSUES deliberate suppressions"
    exit 1
fi
# Exit codes are taken modulo 256, so a status of 256 would surface as success.
# Report the failure with a literal 1 instead of forwarding the raw status.
if [ "$TEST_STATUS" -ne 0 ]; then
    echo "    TESTS FAILED (swift test exited $TEST_STATUS) — see $TEST_LOG"
    exit 1
fi

echo
echo "==> Bench (debug, informational — exercises drbench and catches crashes)"
BENCH_LOG="$LOG_DIR/downright-bench-$LOG_TAG.log"
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
    BENCH_RELEASE_LOG="$LOG_DIR/downright-bench-release-$LOG_TAG.log"
    if ! swift run -c release --scratch-path .build-bench drbench > "$BENCH_RELEASE_LOG" 2>&1; then
        echo "    FAILED — a performance budget was violated (or the build failed)"
        grep -aE "✗|❌|error:" "$BENCH_RELEASE_LOG" | sort -u | head -40
        exit 1
    fi
    grep -aE "Typing response p95|End-to-end semantic convergence" "$BENCH_RELEASE_LOG" || true
    echo "    ok"
fi

exit 0
