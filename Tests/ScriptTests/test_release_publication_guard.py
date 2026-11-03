"""Only a successful lookup with no matching public or draft release may publish."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/check-release-unpublished.py"
SPEC = importlib.util.spec_from_file_location("release_publication_guard", SCRIPT)
GUARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)


class ReleasePublicationGuardTests(unittest.TestCase):
    def setUp(self):
        environment = mock.patch.dict(os.environ, GITHUB_REPOSITORY="owner/project",
                                      GITHUB_SHA="a" * 40)
        environment.start()
        self.addCleanup(environment.stop)

    def check(self, returncode, output, diagnostic=""):
        result = subprocess.CompletedProcess([], returncode, stdout=output, stderr=diagnostic)
        errors = io.StringIO()
        with mock.patch.object(GUARD.subprocess, "run", return_value=result) as request, \
                contextlib.redirect_stderr(errors):
            status = GUARD.main()
        command = request.call_args.args[0]
        self.assertIn("repos/owner/project/releases?per_page=100", command)
        self.assertIn("--paginate", command)
        self.assertIn('select(.tag_name == "auto-' + "a" * 40 + '")', command[-1])
        self.errors = errors.getvalue()
        return status

    def test_missing_release_allows_publication(self):
        self.assertEqual(self.check(0, ""), 0)

    def test_existing_release_blocks_publication(self):
        self.assertNotEqual(self.check(0, "12345\n"), 0)

    def test_api_failures_never_mean_no_release(self):
        for diagnostic in ("HTTP 401 Unauthorized", "HTTP 403 Forbidden",
                           "HTTP 404 Not Found", "HTTP 500 Internal Server Error",
                           "could not connect to api.github.com"):
            with self.subTest(diagnostic=diagnostic):
                self.assertNotEqual(self.check(1, "", diagnostic), 0)
                self.assertIn(diagnostic, self.errors)

    def test_network_failure_and_timeout_block_publication(self):
        for error in (OSError("network unavailable"), subprocess.TimeoutExpired("gh", 30)):
            with self.subTest(error=error), \
                    mock.patch.object(GUARD.subprocess, "run", side_effect=error), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertNotEqual(GUARD.main(), 0)

    def test_invalid_identity_never_queries_a_different_target(self):
        with mock.patch.dict(os.environ, GITHUB_REPOSITORY="invalid", GITHUB_SHA="main"), \
                mock.patch.object(GUARD.subprocess, "run") as request, \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertNotEqual(GUARD.main(), 0)
        request.assert_not_called()


if __name__ == "__main__":
    unittest.main()
