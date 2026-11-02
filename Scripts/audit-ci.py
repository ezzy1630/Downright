#!/usr/bin/env python3
"""Read recent Actions runs and summarize observed durations without changing GitHub."""
import argparse
from datetime import datetime
import json
import math
from pathlib import Path
import statistics
import subprocess


def gh(*arguments):
    return json.loads(subprocess.check_output(["gh", *arguments], text=True))


def seconds(start, end):
    if not start or not end:
        return None
    return (datetime.fromisoformat(end.replace("Z", "+00:00"))
            - datetime.fromisoformat(start.replace("Z", "+00:00"))).total_seconds()


def distribution(values):
    values = sorted(value for value in values if value is not None)
    return dict(samples=len(values), median_seconds=statistics.median(values),
                p95_seconds=values[math.ceil(len(values) * .95)-1]) if values else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="ezzy1630/Downright")
    parser.add_argument("--limit", type=int, default=30)
    parser.add_argument("--workflow", default="ci.yml")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.limit <= 100:
        parser.error("limit must be between 1 and 100")
    runs = gh("run", "list", "--repo", args.repo, "--workflow", args.workflow,
              "--limit", str(args.limit), "--json",
              "databaseId,headSha,createdAt,updatedAt,conclusion,status,url")
    records, groups = [], {}
    for run in runs:
        if run["status"] != "completed":
            continue
        jobs = gh("api", f"repos/{args.repo}/actions/runs/{run['databaseId']}/jobs?per_page=100")["jobs"]
        for job in jobs:
            record = dict(run=run["databaseId"], head=run["headSha"], url=run["url"],
                          name=job["name"], conclusion=job["conclusion"],
                          start_delay_seconds=seconds(run["createdAt"], job["started_at"]),
                          duration_seconds=seconds(job["started_at"], job["completed_at"]),
                          steps=[dict(name=step["name"], conclusion=step["conclusion"],
                                      seconds=seconds(step.get("started_at"), step.get("completed_at")))
                                 for step in job["steps"]])
            records.append(record)
            # Failed and cancelled runs have truncated durations; never mix
            # those into a claimed successful-run speed improvement.
            if job["conclusion"] == "success":
                groups.setdefault(job["name"], []).append(record)
    summary = {name: dict(duration=distribution(row["duration_seconds"] for row in rows),
                          start_delay=distribution(row["start_delay_seconds"] for row in rows))
               for name, rows in groups.items()}
    report = dict(repository=args.repo, workflow=args.workflow, runs_inspected=len(runs),
                  note="Start delay includes dependencies and scheduling; it is not pure runner queue time. "
                       "Actions step durations include setup/build/test together where the workflow groups them. "
                       "Use uploaded ci-report results for compilation, execution and cache provenance.",
                  successful_jobs=summary, jobs=records)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
