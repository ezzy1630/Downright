#!/usr/bin/env python3
"""Run a check with retained logs, phase timings and explicit coverage evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time


def fingerprint():
    paths = subprocess.check_output(
        ["git", "ls-files", "-co", "--exclude-standard", "-z"]
    ).split(b"\0")
    digest = hashlib.sha256()
    for name in sorted(set(paths)):
        if name and Path(os.fsdecode(name)).is_file():
            digest.update(name + b"\0")
            digest.update(Path(os.fsdecode(name)).read_bytes())
    return digest.hexdigest()


def coverage(text):
    # Callers supply raw test logs, not check.sh's echoed summary. Equal counts
    # and rounded durations can belong to independent target executables.
    runs = re.findall(r"Test run with (\d+) tests?[^\n]*?(?:passed|failed) after ([\d.]+) seconds", text)
    skipped = sorted(set(re.findall(r"Test (.+?) skipped[^\n]*", text)))
    xcode = re.findall(
        r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures", text
    )
    if runs:
        executed = sum(int(count) for count, _ in runs)
        execution_seconds = sum(float(duration) for _, duration in runs)
        skipped_count = len(skipped)
    elif xcode:
        total, skips, _ = xcode[-1]
        skipped_count = int(skips or 0)
        executed = int(total) - skipped_count
        execution_seconds = None
    else:
        executed = None
        execution_seconds = None
        skipped_count = len(skipped)
    suites = {name: float(duration) for name, duration in re.findall(
        r"Suite (.+?) (?:passed|failed) after ([\d.]+) seconds", text)}
    return dict(executed=executed, skipped=skipped_count, skipped_tests=skipped,
                slowest_suites=[dict(name=name, seconds=duration) for name, duration
                                in sorted(suites.items(), key=lambda item: item[1], reverse=True)[:10]],
                execution_seconds=execution_seconds,
                real_window_performance="not executed" if "REAL_WINDOW_PERF SKIP:" in text
                or any("10k-line" in name or "five-frame" in name or "50k-line" in name
                       or "IME marked" in name or "external atomic rewrite" in name for name in skipped)
                else "synchronous display checks executed; compositor frames unverified" if "REAL_WINDOW_PERF " in text
                else "not measured by this command")


def compilation_logs(directory):
    records = []
    for path in sorted(directory.rglob("*.log")):
        if path.name == "run.log":
            continue
        text = path.read_text(errors="replace")
        units = re.findall(r"(?:Compiling|SwiftCompile[^\n]*?normal \w+) ([^\n]+)", text)
        units += re.findall(r"-primary-file ([^\s]+)", text)
        records.append(dict(path=str(path.relative_to(directory)),
                            compilation_units=len(units), units=units,
                            build_seconds=re.findall(r"Build complete! \(([\d.]+)s\)", text)))
    return records


def run(args):
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # A new directory binds test logs to this invocation, even when the output
    # destination is reused. Retain it with the evidence rather than guessing
    # freshness from filesystem timestamps.
    temporary = Path(tempfile.mkdtemp(prefix="run-", dir=output))
    start_source = fingerprint()
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    environment = dict(os.environ, TMPDIR=str(temporary) + os.sep,
                       CHECK_EVIDENCE_DIRECTORY=str(output))
    started = time.monotonic()
    phases = []
    current = None
    status = 1
    child = None

    def forward_signal(number, _frame):
        if child is not None and child.poll() is None:
            os.killpg(child.pid, number)

    previous = {number: signal.signal(number, forward_signal)
                for number in (signal.SIGTERM, signal.SIGINT)}
    try:
        with (output / "run.log").open("w") as log:
            child = subprocess.Popen(args.command, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True, errors="replace",
                                     env=environment, start_new_session=True)
            for line in child.stdout:
                print(line, end="", flush=True)
                log.write(line)
                log.flush()
                if line.startswith("==> "):
                    now = time.monotonic()
                    if current is not None:
                        phases.append(dict(name=current[0], seconds=now-current[1]))
                    current = (line[4:].strip(), now)
            status = child.wait()
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)
        if current is not None:
            phases.append(dict(name=current[0], seconds=time.monotonic()-current[1]))
        logs = sorted(temporary.glob("downright-test-*.log"))
        text = "\n".join(path.read_text(errors="replace") for path in logs) if logs else (
            (output / "run.log").read_text(errors="replace") if (output / "run.log").exists() else ""
        )
        result = coverage(text)
        changed = start_source != fingerprint()
        if changed or (args.require_tests and not result["executed"]):
            status = status or 1
        report = dict(name=args.name, head=head, source_sha256=start_source,
                      source_changed=changed, exit_status=status,
                      elapsed_seconds=time.monotonic()-started, phases=phases,
                      coverage=result, compilation=compilation_logs(temporary),
                      cache=dict(requested=os.environ.get("CI_CACHE_REQUESTED_KEY"),
                                 restored=os.environ.get("CI_CACHE_MATCHED_KEY"),
                                 exact_hit=os.environ.get("CI_CACHE_EXACT_HIT") == "true"))
        (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
        summary = [f"### {args.name}", "", f"Commit: `{head}`; source digest: `{start_source}`.",
                   f"Result: {'passed' if status == 0 else 'failed'}; {report['elapsed_seconds']:.2f}s.", "",
                   "| Phase | Seconds |", "|---|---:|"]
        summary += [f"| {phase['name']} | {phase['seconds']:.2f} |" for phase in phases]
        summary += ["", f"Executed: {result['executed'] if result['executed'] is not None else 'unavailable'}; "
                    f"skipped: {result['skipped']}; real-window performance: {result['real_window_performance']}."]
        if result["execution_seconds"] is not None:
            summary += [f"Swift test execution: {result['execution_seconds']:.3f}s (compilation excluded)."]
        if args.require_tests and not result["executed"]:
            summary += ["ERROR: required test execution evidence is missing."]
        if changed:
            summary += ["ERROR: source changed during validation; discard this result."]
        if report["cache"]["requested"]:
            summary += [f"Cache: {'exact match' if report['cache']['exact_hit'] else 'fallback restore' if report['cache']['restored'] else 'cold'}."]
        if result["skipped_tests"]:
            summary += ["", "Skipped coverage:"] + [f"- {name}" for name in result["skipped_tests"]]
        if result["slowest_suites"]:
            summary += ["", "| Slowest suite | Execution seconds |", "|---|---:|"]
            summary += [f"| {row['name']} | {row['seconds']:.3f} |" for row in result["slowest_suites"]]
        rendered = "\n".join(summary) + "\n"
        (output / "summary.md").write_text(rendered)
        if summary_path := os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(summary_path, "a") as stream:
                stream.write(rendered)
        print(f"Evidence: {output / 'results.json'}")
    return status if status >= 0 else 128 - status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--require-tests", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("a command is required after --")
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
