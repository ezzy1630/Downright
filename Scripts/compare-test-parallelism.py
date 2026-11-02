#!/usr/bin/env python3
"""Compare only isolated MarkdownCore tests; AppKit tests remain serialized."""
import argparse
from contextlib import suppress
import importlib.util
import json
import os
from pathlib import Path
import signal
import statistics
import subprocess
import sys
import tempfile
import time


def require_artifact_path(path):
    root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
    try:
        relative = Path(path).resolve().relative_to(root)
    except ValueError:
        return  # External artifacts do not enter the source fingerprint.
    if subprocess.run(["git", "check-ignore", "--quiet", str(relative) + "/"]).returncode:
        raise SystemExit(f"Artifact directory must be outside the repository or git-ignored: {path}")


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
    frameworks = Path("/Library/Developer/CommandLineTools/Library/Developer/Frameworks")
    selected = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True).stdout.strip()
    flags = ["-Xswiftc", "-F", "-Xswiftc", str(frameworks)] if (
        selected.startswith("/Library/Developer/CommandLineTools") and (frameworks / "Testing.framework").is_dir()
    ) else []
    scratch = os.environ.get("TEST_SCRATCH") or args.scratch_path + ("-test" if flags else "")
    require_artifact_path(scratch)
    require_artifact_path(args.output)
    before = report.fingerprint()
    args.output.mkdir(parents=True, exist_ok=True)
    # Bind --skip-build trials to fresh build products, not an older checkout
    # that happened to use the caller's scratch directory.
    with (args.output / "build.log").open("w") as log:
        build = subprocess.run(["swift", "build", "--build-tests", "--scratch-path", scratch, *flags],
                               stdout=log, stderr=subprocess.STDOUT)
        if build.returncode:
            raise SystemExit(f"swift build failed; see {args.output / 'build.log'}")
    trials = []
    for repeat in range(args.repeats):
        # Alternate ordering to avoid consistently giving one mode warm caches.
        modes = ("serial", "parallel") if repeat % 2 == 0 else ("parallel", "serial")
        for mode in modes:
            command = ["swift", "test", "--skip-build", "--scratch-path", scratch,
                       "--filter", "MarkdownCoreTests", "--no-parallel" if mode == "serial" else "--parallel", *flags]
            started = time.monotonic()
            with tempfile.TemporaryDirectory(prefix="downright-core-trial-") as support:
                process = subprocess.Popen(command, env=dict(os.environ, DOWNRIGHT_SUPPORT_DIRECTORY=support),
                                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
                try:
                    log, _ = process.communicate(timeout=600)
                except subprocess.TimeoutExpired:
                    with suppress(ProcessLookupError):
                        os.killpg(process.pid, signal.SIGTERM)
                    try:
                        log, _ = process.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        with suppress(ProcessLookupError):
                            os.killpg(process.pid, signal.SIGKILL)
                        log, _ = process.communicate()
                    path = args.output / f"{mode}-{repeat}.log"
                    path.write_text(log)
                    raise SystemExit(f"{mode} trial exceeded 600 seconds; see {path}")
            duration = time.monotonic()-started
            (args.output / f"{mode}-{repeat}.log").write_text(log)
            coverage = report.coverage(log)
            if process.returncode or not coverage["executed"]:
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
