#!/bin/bash
# Run Swift tests through the same toolchain and isolation as the source gate.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SCRATCH="${SCRATCH:-.build-main}"
TEST_SELECTION=()
case "$#" in
    0) ;;
    2)
        if [ "$1" != "--filter" ] || [ -z "$2" ]; then
            echo "Usage: Scripts/test.sh [--filter REGEX]" >&2
            exit 2
        fi
        TEST_SELECTION=(--filter "$2")
        ;;
    *) echo "Usage: Scripts/test.sh [--filter REGEX]" >&2; exit 2 ;;
esac

# Never inherit a development or installed app's support state.
if ! TEST_SUPPORT_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/downright-test-support.XXXXXX")"; then
    echo "test: could not create an isolated Application Support directory" >&2
    exit 1
fi
export DOWNRIGHT_SUPPORT_DIRECTORY="$TEST_SUPPORT_DIRECTORY"
trap 'find "$TEST_SUPPORT_DIRECTORY" -depth -delete' EXIT
# UI driver failure snapshots land with the run's evidence, which CI uploads.
if [ -n "${CHECK_EVIDENCE_DIRECTORY:-}" ] && [ -z "${DOWNRIGHT_UI_TEST_ARTIFACTS:-}" ]; then
    export DOWNRIGHT_UI_TEST_ARTIFACTS="$CHECK_EVIDENCE_DIRECTORY/ui-failures"
fi

LOG_TAG="$(printf '%s' "$SCRATCH" | tr -c 'A-Za-z0-9._-' '-')"
LOG_DIR="${TMPDIR:-/tmp}"
LOG_PREFIX="$LOG_DIR/downright-test-$LOG_TAG"
TEST_LOG="$LOG_PREFIX.log"
CLI_BUILD_LOG="$LOG_DIR/downright-cli-build-$LOG_TAG.log"
VERBOSE_FLAG=""
if [ "${CHECK_VERBOSE_BUILD:-0}" = "1" ]; then VERBOSE_FLAG=--verbose; fi

# CLT ships Testing.framework outside SwiftPM's default search paths. Without
# -F the generated runner can compile out Swift Testing and execute zero tests.
CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
TEST_FLAGS=()
SELECTED_DEVELOPER="$(xcode-select -p 2>/dev/null || true)"
if [[ "$SELECTED_DEVELOPER" == /Library/Developer/CommandLineTools* ]] \
    && [ -d "$CLT_FRAMEWORKS/Testing.framework" ]; then
    TEST_FLAGS=(-Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS")
    TEST_SCRATCH="${TEST_SCRATCH:-${SCRATCH}-test}"
else
    TEST_SCRATCH="${TEST_SCRATCH:-$SCRATCH}"
fi

# Worker tests launch the actual CLI. Build that product even on a cold
# focused run. In the source gate it is already in the debug build graph.
if ! swift build --scratch-path "$SCRATCH" --product down > "$CLI_BUILD_LOG" 2>&1; then
    tail -40 "$CLI_BUILD_LOG" >&2
    exit 1
fi
if ! CLI_BIN_DIRECTORY="$(swift build --scratch-path "$SCRATCH" --show-bin-path)"; then
    echo "test: cannot locate the built CLI for worker tests" >&2
    exit 1
fi
export DOWNRIGHT_TEST_CLI_EXECUTABLE="$CLI_BIN_DIRECTORY/down"

run_swift_tests() {
    swift test ${VERBOSE_FLAG:+"$VERBOSE_FLAG"} --no-parallel --scratch-path "$TEST_SCRATCH" \
        ${TEST_FLAGS[@]+"${TEST_FLAGS[@]}"} ${TEST_SELECTION[@]+"${TEST_SELECTION[@]}"}
}
if [ "${CI:-}" = "true" ]; then
    # Preserve progress and collect stack evidence from this gate's own descendants.
    python3 -u "$ROOT/Scripts/sample-test-processes.py" \
        --parent-pid "$$" --output-prefix "$LOG_PREFIX" &
    TEST_DIAGNOSTICS_PID=$!
    NSUnbufferedIO=YES run_swift_tests 2>&1 | tee "$TEST_LOG"
    TEST_STATUS=$?
    kill "$TEST_DIAGNOSTICS_PID" 2>/dev/null || true
    wait "$TEST_DIAGNOSTICS_PID" 2>/dev/null || true
else
    run_swift_tests > "$TEST_LOG" 2>&1
    TEST_STATUS=$?
fi

grep -aE "Test run|✘|Suite .* (passed|failed)|error:|failed after" "$TEST_LOG" | tail -40
if [ "$TEST_STATUS" -ne 0 ]; then
    echo "    Failure details"
    grep -aE -A 3 "✘|Expectation failed|Issue recorded|error:|failed after" "$TEST_LOG" | head -120
    echo "    TESTS FAILED (swift test exited $TEST_STATUS) — see $TEST_LOG"
    exit 1
fi

# Read completed Swift Testing summaries, subtracting skipped tests. XCTest
# can also emit a successful zero count on a Swift Testing-only toolchain.
COUNT="$(LC_ALL=en_US.UTF-8 awk '
    /^[✔✘] Test run with [0-9]+ tests?/ { count += $5 }
    /^➜ Test .* skipped/ { skipped++ }
    END { print count - skipped }
' "$TEST_LOG")"
# A test runner can stop after AppKit event posting without a summary yet exit
# 0 (https://github.com/swiftlang/swift/issues/91716). Every started Swift
# Testing run must reach its completion line, or its tests did not all run.
STARTED="$(grep -ac '^◇ Test run started' "$TEST_LOG")"
FINISHED="$(grep -acE '^[✔✘] Test run with [0-9]+ tests?' "$TEST_LOG")"
if [ "$STARTED" -ne "$FINISHED" ]; then
    echo "    INCOMPLETE — $STARTED Swift Testing runs started but $FINISHED finished ($TEST_LOG)"
    exit 1
fi
if ! [[ "$COUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo "    NO TESTS RAN — check the filter or selected Swift toolchain ($TEST_LOG)"
    exit 1
fi
echo "    $COUNT tests executed"
