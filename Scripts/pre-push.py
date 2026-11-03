#!/usr/bin/env python3
"""Check the exact commits proposed to Git, even when the checkout is dirty."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    # Hooks export repository-local Git variables. Clear them before creating
    # or inspecting a foreign snapshot, or git init can modify the real repo.
    local_git_variables = subprocess.check_output(
        ["git", "rev-parse", "--local-env-vars"], text=True,
    ).splitlines()
    snapshot_environment = {key: value for key, value in os.environ.items()
                            if key not in local_git_variables}
    seen = set()
    for line in sys.stdin:
        fields = line.split()
        if len(fields) != 4:
            raise ValueError("malformed Git pre-push ref input")
        local_ref, revision, _, _ = fields
        if set(revision) == {"0"} or revision in seen:
            continue  # A deletion has no proposed tree to validate.
        seen.add(revision)
        commit = subprocess.check_output(["git", "rev-parse", "--verify", revision + "^{commit}"], text=True).strip()
        print(f"Checking proposed {local_ref} at {commit}", flush=True)
        with tempfile.TemporaryDirectory(prefix="downright-pre-push-") as directory:
            archive = subprocess.Popen(["git", "archive", commit], stdout=subprocess.PIPE)
            try:
                extracted = subprocess.run(["tar", "-x", "-C", directory], stdin=archive.stdout)
            finally:
                archive.stdout.close()
            if archive.wait() != 0 or extracted.returncode != 0:
                return 1
            # Actionlint resolves local actions/reusable workflows from a Git
            # project root. Metadata is disposable; proposed files stay exact.
            subprocess.run(["git", "init", "--quiet", directory], check=True,
                           stdout=subprocess.DEVNULL, env=snapshot_environment)
            environment = dict(snapshot_environment, CHECK_ROOT=directory)
            environment["ACTIONLINT"] = environment.get("ACTIONLINT") or str(Path(__file__).resolve().parents[1] / ".build-tools/actionlint")
            result = subprocess.run([str(Path(directory) / "Scripts/check-fast.sh")],
                                    env=environment)
            if result.returncode:
                return result.returncode
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"pre-push failed: {error}")
