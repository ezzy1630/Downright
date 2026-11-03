"""Publication must require an explicit request against the main branch."""
import os
from pathlib import Path
import subprocess
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/validate-release-request.sh"


class ReleaseRequestTests(unittest.TestCase):
    def request(self, event, ref):
        environment = dict(os.environ, GITHUB_EVENT_NAME=event, GITHUB_REF=ref)
        return subprocess.run(
            ["/bin/bash", str(SCRIPT)], env=environment,
            capture_output=True, text=True, timeout=5,
        )

    def test_manual_main_release_is_accepted(self):
        result = self.request("workflow_dispatch", "refs/heads/main")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_automatic_events_cannot_publish_main(self):
        for event in ("push", "pull_request", "workflow_run", "schedule", ""):
            with self.subTest(event=event):
                result = self.request(event, "refs/heads/main")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("manual workflow_dispatch", result.stderr)

    def test_manual_requests_cannot_publish_other_refs(self):
        for ref in ("refs/heads/feature", "refs/tags/main", "main", ""):
            with self.subTest(ref=ref):
                result = self.request("workflow_dispatch", ref)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("refs/heads/main", result.stderr)


if __name__ == "__main__":
    unittest.main()
