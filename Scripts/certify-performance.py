#!/usr/bin/env python3
"""Compare unchanged release cases and fresh native-session peak evidence.

The comparison uses conservative bounds for drbench's 0.001 ms rounding.
It does not establish visible frame delivery or Finder acceptance.
"""
import argparse
import json
import math
from pathlib import Path
import re
import sys

CASES = {
    "cmark alone": "cmark conversion",
    "MarkdownParser.parse, all passes": "Full parse",
    "ASTDiff.dirtySet, one-character edit": "AST diff",
    "TextDiff.hunks, external rewrite": "Text diff",
    "incremental, one dirty block": "Incremental decoration",
    "wholesale (mode switch)": "Wholesale decoration",
    "edit + paragraph map": "Typing/storage",
    "worker pipeline": "Semantic convergence",
    "parse 100 KB": "Parse 100 KB",
    "syntax highlight 10 KB Swift": "Syntax highlighting",
}
ROW = re.compile(r"^\s*(.*?)\s+p50\s+([0-9.]+) ms\s+p95\s+([0-9.]+) ms\s+max\s+([0-9.]+) ms \(n=(\d+)\)")
MEMORY_LIMIT_BYTES = 150_000_000
ACTIONS = {"open", "edit-save-undo-save", "scroll", "mode-cycles"}


def timings(path):
    source = path.read_text()
    for marker in ["build: release", "corpus: 120825 chars, 4885 lines", "cold-open corpus: 100000 chars"]:
        if marker not in source:
            raise ValueError(f"{path}: missing unchanged release corpus marker {marker!r}")
    rows = {}
    for line in source.splitlines():
        match = ROW.match(line)
        if not match or match[1] not in CASES:
            continue
        label = match[1]
        if label in rows:
            raise ValueError(f"{path}: duplicate case {label}")
        p50, p95, maximum = map(float, match.group(2, 3, 4))
        if not all(math.isfinite(x) and x > 0 for x in [p50, p95, maximum]):
            raise ValueError(f"{path}: invalid duration for {label}")
        rows[label] = (p95, int(match[5]))
    if missing := CASES.keys() - rows.keys():
        raise ValueError(f"{path}: missing cases: {', '.join(sorted(missing))}")
    return rows


def native_sessions(paths):
    if len(paths) < 3:
        raise ValueError("Full certification requires three fresh native-session records")
    pids, artifacts = set(), set()
    peaks = []
    for path in paths:
        record = json.loads(path.read_text())
        pid = record["pid"]
        if not isinstance(pid, int) or pid <= 0 or pid in pids:
            raise ValueError(f"{path}: expected a distinct fresh process")
        pids.add(pid)
        artifact = record["artifact_sha256"]
        before = record["source_sha256_before"]
        after = record["source_sha256_after"]
        if not all(re.fullmatch(r"[0-9a-f]{64}", x) for x in [artifact, before, after]):
            raise ValueError(f"{path}: invalid evidence digest")
        if before != after:
            raise ValueError(f"{path}: source bytes were not restored")
        if not ACTIONS.issubset(record["completed_actions"]):
            raise ValueError(f"{path}: native workload is incomplete")
        artifacts.add(artifact)
        peak = float(record["peak_physical_mib"])
        if not math.isfinite(peak) or peak <= 0:
            raise ValueError(f"{path}: invalid kernel lifetime peak")
        peaks.append(peak)
    if len(artifacts) != 1:
        raise ValueError("Native records must exercise the same executable")
    return max(peaks)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, action="append", required=True)
    parser.add_argument("--memory", type=Path, action="append", default=[])
    parser.add_argument("--timings-only", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        before = timings(args.baseline)
        after = [timings(path) for path in args.candidate]
        results = []
        for case, name in CASES.items():
            base, count = before[case]
            if any(rows[case][1] != count for rows in after):
                raise ValueError(f"{name}: sample count changed")
            candidate = max(rows[case][0] for rows in after)
            # Each printed number was rounded to 0.001 ms. Require 25% even
            # at the least favorable pair of underlying unrounded values.
            passed = candidate + 0.0005 <= (base - 0.0005) * 0.75
            results.append(dict(metric=name, baseline_p95_ms=base,
                                candidate_p95_ms=candidate,
                                improvement_percent=100 * (1 - candidate / base), passed=passed))
        peak = None if args.timings_only else native_sessions(args.memory)
        passed = all(row["passed"] for row in results) and (peak is None or peak * 2**20 < MEMORY_LIMIT_BYTES)
        report = dict(passed=passed, scope="timings only" if args.timings_only else "timings and native-session peak",
                      baseline=str(args.baseline), candidates=list(map(str, args.candidate)),
                      memory_records=list(map(str, args.memory)), metrics=results, peak_physical_mib=peak, memory_limit_bytes=MEMORY_LIMIT_BYTES)
        print("| Metric | Before p95 | After p95 (worst run) | Faster | Result |")
        print("|---|---:|---:|---:|---|")
        for row in results:
            print(f"| {row['metric']} | {row['baseline_p95_ms']:.3f} ms | {row['candidate_p95_ms']:.3f} ms | {row['improvement_percent']:.1f}% | {'PASS' if row['passed'] else 'FAIL'} |")
        if peak is not None:
            print(f"\nNative lifetime peak: {peak:.2f} MiB / strictly below 150 MB: {'PASS' if peak * 2**20 < MEMORY_LIMIT_BYTES else 'FAIL'}")
        else:
            print("\nTiming comparison only; native memory is not certified.")
        if args.output:
            args.output.write_text(json.dumps(report, indent=2) + "\n")
        return 0 if passed else 1
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Performance certification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
