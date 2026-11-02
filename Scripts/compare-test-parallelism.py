#!/usr/bin/env python3
"""Compare only isolated MarkdownCore tests; AppKit tests remain serialized."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch-path", required=True)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.repeats <= 10:
        parser.error("repeats must be between 1 and 10")
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("ci_report", Path(__file__).with_name("ci-report.py"))
    report = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(report)
    before = report.fingerprint()
    args.output.mkdir(parents=True, exist_ok=True)
    # Bind --skip-build trials to fresh build products, not an older checkout
    # that happened to use the caller's scratch directory.
    with (args.output / "build.log").open("w") as log:
        subprocess.run(["swift", "build", "--build-tests", "--scratch-path", args.scratch_path],
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    trials = []
    for repeat in range(args.repeats):
        # Alternate ordering to avoid consistently giving one mode warm caches.
        modes = ("serial", "parallel") if repeat % 2 == 0 else ("parallel", "serial")
        for mode in modes:
            command = ["swift", "test", "--skip-build", "--scratch-path", args.scratch_path,
                       "--filter", "MarkdownCoreTests", "--no-parallel" if mode == "serial" else "--parallel"]
            started = time.monotonic()
            with tempfile.TemporaryDirectory(prefix="downright-core-trial-") as support:
                result = subprocess.run(command, env=dict(os.environ, DOWNRIGHT_SUPPORT_DIRECTORY=support),
                                        capture_output=True, text=True)
            duration = time.monotonic()-started
            log = result.stdout + result.stderr
            (args.output / f"{mode}-{repeat}.log").write_text(log)
            coverage = report.coverage(log)
            if result.returncode or not coverage["executed"]:
                raise SystemExit(f"{mode} trial failed or ran no tests; see {args.output}")
            trials.append(dict(mode=mode, seconds=duration, coverage=coverage))
    counts = {row["coverage"]["executed"] for row in trials}
    if len(counts) != 1 or before != report.fingerprint():
        raise SystemExit("Experiment invalid: executed coverage or source changed")
    medians = {mode: statistics.median(row["seconds"] for row in trials if row["mode"] == mode)
               for mode in ("serial", "parallel")}
    (args.output / "results.json").write_text(json.dumps(dict(
        source_sha256=before, trials=trials, median_seconds=medians,
        note="Wall time excludes compilation; default source gate remains serial."), indent=2) + "\n")
    print(json.dumps(medians, indent=2))


if __name__ == "__main__":
    main()
