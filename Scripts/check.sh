#!/bin/bash
# Build everything and run every source suite. CI splits out the unchanged
# release benchmark so its independent toolchain graph can run in parallel.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export SCRATCH="${SCRATCH:-.build-main}"
LOG_TAG="$(printf '%s' "$SCRATCH" | tr -c 'A-Za-z0-9._-' '-')"
LOG_DIR="${TMPDIR:-/tmp}"
VERBOSE_FLAG=""
if [ "${CHECK_VERBOSE_BUILD:-0}" = "1" ]; then VERBOSE_FLAG=--verbose; fi

case "${1:-}" in
    "") ;;
    --source-only) ;;
    --bench-only) RUN_DRBENCH=1 ;;
    *) echo "Usage: Scripts/check.sh [--source-only | --bench-only]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
    echo "Usage: Scripts/check.sh [--source-only | --bench-only]" >&2
    exit 2
fi

if [ "${1:-}" != "--bench-only" ]; then
    run_source() {
        echo "==> Test honesty"
        python3 -B Scripts/lint-tests.py || exit 1

        echo "==> Python script regression tests"
        if ! python3 -B - <<'PY'
import sys
import unittest

suite = unittest.defaultTestLoader.discover("Tests/ScriptTests", pattern="test_*.py")
if suite.countTestCases() == 0:
    sys.exit("Python script regression suite discovered no tests")
result = unittest.TextTestRunner().run(suite)
sys.exit(0 if result.wasSuccessful() and result.testsRun > 0 else 1)
PY
        then
            echo "    FAILED"
            exit 1
        fi

        echo "==> Build"
        if ! swift build ${VERBOSE_FLAG:+"$VERBOSE_FLAG"} --scratch-path "$SCRATCH" > "$LOG_DIR/downright-build-$LOG_TAG.log" 2>&1; then
            echo "    FAILED"
            grep "error:" "$LOG_DIR/downright-build-$LOG_TAG.log" | sort -u | head -40
            exit 1
        fi
        echo "    ok"

        echo "==> Spotlight importer build"
        if ! swift build ${VERBOSE_FLAG:+"$VERBOSE_FLAG"} --scratch-path "$SCRATCH" --product DownrightSpotlightImporter \
            > "$LOG_DIR/downright-spotlight-build-$LOG_TAG.log" 2>&1; then
            echo "    FAILED"
            grep "error:" "$LOG_DIR/downright-spotlight-build-$LOG_TAG.log" | sort -u | head -40
            exit 1
        fi
        echo "    ok"

        echo "==> Tests"
        Scripts/test.sh || exit 1

        echo "==> Version consistency (single source: Config/version.env)"
        # This script runs without `set -e` on purpose (the test step inspects its own
        # status), so every gate here must be checked explicitly.  A drift report that
        # only prints is a release gate that always passes.
        if ! "$ROOT/Scripts/sync-versions.sh"; then
            echo "    FAILED"
            exit 1
        fi

        echo
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
        # Same rule as the version gate above: a WCAG regression must fail the run,
        # not just decorate its output.
        if ! python3 "$ROOT/Scripts/check-contrast.py"; then
            echo "    FAILED"
            exit 1
        fi

        echo
    }
    run_source || exit 1
fi
if [ "${1:-}" = "--source-only" ]; then exit 0; fi

# `RUN_DRBENCH=1 Scripts/check.sh` builds release and treats the budget as a
# gate. Run the corpus once: release enforces the product budgets, while the
# default debug run only checks that the tool runs.
if [ "${RUN_DRBENCH:-0}" = "1" ]; then
    echo "==> Bench (release, budgets enforced)"
    BENCH_RELEASE_LOG="$LOG_DIR/downright-bench-release-$LOG_TAG.log"
    if ! swift run ${VERBOSE_FLAG:+"$VERBOSE_FLAG"} -c release --scratch-path "${BENCH_SCRATCH:-${SCRATCH}-bench}" drbench > "$BENCH_RELEASE_LOG" 2>&1; then
        echo "    FAILED — a performance budget was violated (or the build failed)"
        # Both halves are needed. SwiftPM compiles in parallel, so a build
        # failure's `error:` lines can be followed by enough output from other
        # in-flight modules to push them past the tail; a budget miss, in
        # contrast, is only legible in the run's full table.
        grep -aE "✗|❌|error:" "$BENCH_RELEASE_LOG" | sort -u | head -40
        echo "    --- last 80 lines ---"
        tail -80 "$BENCH_RELEASE_LOG"
        exit 1
    fi
    grep -aE "Typing response p95|End-to-end semantic convergence" "$BENCH_RELEASE_LOG" || true
    echo "    ok"
else
    echo "==> Bench (debug, informational — exercises drbench and catches crashes)"
    BENCH_LOG="$LOG_DIR/downright-bench-$LOG_TAG.log"
    if ! swift run ${VERBOSE_FLAG:+"$VERBOSE_FLAG"} --scratch-path "$SCRATCH" drbench > "$BENCH_LOG" 2>&1; then
        echo "    FAILED"
        tail -30 "$BENCH_LOG"
        exit 1
    fi
    grep -aE "Typing response p95|End-to-end semantic convergence" "$BENCH_LOG" || true
    echo "    ok"
fi

exit 0
