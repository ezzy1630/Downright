#!/usr/bin/env python3
"""Capture an overdue CI test phase without changing its exit status or deadline."""
import argparse
import os
from pathlib import Path
import subprocess
import time


def descendant_processes(table, parent_pid):
    rows = {}
    for line in table.splitlines():
        columns = line.split(None, 4)
        if len(columns) != 5:
            continue
        pid, parent = int(columns[0]), int(columns[1])
        rows[pid] = (parent, columns[2], columns[3], columns[4])
    owned = {parent_pid}
    while True:
        children = {pid for pid, row in rows.items() if row[0] in owned}
        if children <= owned:
            break
        owned |= children
    return {pid: rows[pid] for pid in rows if pid in owned and pid != parent_pid}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--parent-pid", type=int, required=True)
    parser.add_argument("--delay-seconds", type=float, default=900)
    parser.add_argument("--output-prefix", required=True)
    args = parser.parse_args()
    time.sleep(args.delay_seconds)
    # If the gate died, this watcher is orphaned. Do not follow a reused PID
    # into an unrelated session.
    if os.getppid() != args.parent_pid:
        return
    table = subprocess.check_output(
        ["ps", "-A", "-o", "pid=,ppid=,etime=,pcpu=,comm="], text=True,
    )
    processes = descendant_processes(table, args.parent_pid)
    print("\n==> Long-running test phase: owned process diagnostics", flush=True)
    for pid, (parent, elapsed, cpu, command) in processes.items():
        print(f"pid={pid} parent={parent} elapsed={elapsed} cpu={cpu} command={command}", flush=True)
    # Include a stuck test executable or its driver; compiler stacks distinguish
    # a type-checking stall from a runtime wait. Never sample another job/session.
    candidates = [pid for pid, row in processes.items()
                  if os.path.basename(row[3]).endswith("Tests") or "swift" in os.path.basename(row[3])]
    candidates.sort(key=lambda pid: not os.path.basename(processes[pid][3]).endswith("Tests"))
    for pid in candidates[:4]:
        output = Path(f"{args.output_prefix}.sample-{pid}.txt")
        try:
            result = subprocess.run(
                ["sample", str(pid), "1", "1", "-file", str(output)],
                capture_output=True, text=True, timeout=10,
            )
            print(result.stdout + result.stderr, flush=True)
            if output.exists():
                print(output.read_text(errors="replace"), flush=True)
        except (OSError, subprocess.TimeoutExpired) as error:
            print(f"sample {pid} unavailable: {error}", flush=True)


if __name__ == "__main__":
    main()
