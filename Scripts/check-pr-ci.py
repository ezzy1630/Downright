#!/usr/bin/env python3
"""Read the actual hosted source/native checks for an exact PR head."""
import argparse
import json
import subprocess
import sys

REQUIRED_CHECKS = ("swift", "app-acceptance")


def summarize(checks):
    latest = {}
    for check in checks:
        if check.get("app", {}).get("slug") != "github-actions":
            continue
        name = check.get("name")
        if name in REQUIRED_CHECKS and check.get("id", 0) > latest.get(name, {}).get("id", -1):
            latest[name] = check
    gates = [{"name": name,
              "status": latest.get(name, {}).get("status", "missing"),
              "conclusion": latest.get(name, {}).get("conclusion"),
              "url": latest.get(name, {}).get("details_url")}
             for name in REQUIRED_CHECKS]
    if any(gate["status"] == "completed" and gate["conclusion"] != "success" for gate in gates):
        state = "failed"
    elif all(gate["status"] == "completed" and gate["conclusion"] == "success" for gate in gates):
        state = "passed"
    else:
        state = "pending"
    return {"state": state, "gates": gates}


def gh_json(*arguments):
    return json.loads(subprocess.check_output(["gh", *arguments], text=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pr", type=int, required=True)
    parser.add_argument("--repo", help="Defaults to the current checkout's GitHub repository")
    args = parser.parse_args()
    repository = args.repo or gh_json("repo", "view", "--json", "nameWithOwner")["nameWithOwner"]
    pr = gh_json("pr", "view", str(args.pr), "--repo", repository,
                 "--json", "headRefOid,url")
    head = pr["headRefOid"]
    # Manual workflow runs can be absent from the PR's statusCheckRollup even
    # though their actual check runs are attached to this exact commit.
    pages = gh_json("api", f"repos/{repository}/commits/{head}/check-runs?per_page=100",
                    "--paginate", "--slurp")
    checks = [check for page in pages for check in page["check_runs"]]
    report = {"head": head, "pr": pr["url"], **summarize(checks)}
    print(json.dumps(report, indent=2))
    return 0 if report["state"] == "passed" else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(f"check-pr-ci: unable to verify hosted checks: {error}")
