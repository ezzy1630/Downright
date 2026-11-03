"""The push gate must inspect proposed commits, not unrelated working files."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/pre-push.py"


class PrePushTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="downright-push-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.environment = dict(os.environ, GIT_AUTHOR_NAME="Gate Test", GIT_COMMITTER_NAME="Gate Test",
                                GIT_AUTHOR_EMAIL="gate@example.invalid", GIT_COMMITTER_EMAIL="gate@example.invalid")
        self.git("init", "-q")
        (self.root / "Scripts").mkdir()
        check = self.root / "Scripts/check-fast.sh"
        check.write_text('#!/bin/bash\nset -euo pipefail\n[ "$(git -C "$CHECK_ROOT" rev-parse --show-toplevel)" = "$(cd "$CHECK_ROOT" && pwd -P)" ]\ncat "$CHECK_ROOT/value" >> "$PUSH_TEST_LOG"\n'
                         'if [ -e "$CHECK_ROOT/reject" ]; then exit 23; fi\n')
        check.chmod(0o755)
        self.environment["PUSH_TEST_LOG"] = str(self.root / "observed")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, env=self.environment, text=True).strip()

    def commit(self, value):
        (self.root / "value").write_text(value + "\n")
        self.git("add", "Scripts", "value")
        if (self.root / "reject").exists():
            self.git("add", "reject")
        self.git("commit", "-qm", "fixture")
        return self.git("rev-parse", "HEAD")

    def push_input(self, text):
        return subprocess.run([sys.executable, "-B", str(SCRIPT)], input=text, text=True,
                              cwd=self.root, env=self.environment, capture_output=True, timeout=15)

    def test_exact_pushed_revisions_are_checked_despite_dirty_checkout(self):
        first = self.commit("first")
        second = self.commit("second")
        (self.root / "value").write_text("uncommitted\n")
        (self.root / "Scripts/check-fast.sh").write_text("#!/bin/bash\nexit 99\n")
        zero = "0" * 40
        result = self.push_input(f"refs/heads/one {first} refs/heads/one {zero}\n"
                                 f"refs/heads/two {second} refs/heads/two {zero}\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "observed").read_text(), "first\nsecond\n")
        self.assertEqual((self.root / "value").read_text(), "uncommitted\n")

    def test_failed_snapshot_check_rejects_the_push(self):
        (self.root / "reject").touch()
        revision = self.commit("rejected")
        result = self.push_input(f"refs/heads/main {revision} refs/heads/main {'0' * 40}\n")
        self.assertEqual(result.returncode, 23)

    def test_ref_deletion_has_no_tree_to_validate(self):
        revision = self.commit("old")
        result = self.push_input(f"(delete) {'0' * 40} refs/heads/old {revision}\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "observed").exists())

    def test_hook_git_environment_cannot_redirect_snapshot_initialization(self):
        revision = self.commit("isolated")
        git_directory = self.git("rev-parse", "--absolute-git-dir")
        self.environment.update(GIT_DIR=git_directory, GIT_COMMON_DIR=git_directory,
                                GIT_WORK_TREE=str(self.root))
        result = self.push_input(f"refs/heads/feature {revision} refs/heads/feature {'0' * 40}\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "observed").read_text(), "isolated\n")
        self.assertEqual(self.git("config", "--bool", "core.bare"), "false")
        self.assertEqual(self.git("rev-parse", "--show-toplevel"), str(self.root.resolve()))


if __name__ == "__main__":
    unittest.main()
