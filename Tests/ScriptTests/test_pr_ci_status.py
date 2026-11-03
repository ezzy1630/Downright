import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "Scripts" / "check-pr-ci.py"
SPEC = importlib.util.spec_from_file_location("check_pr_ci", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def check(name, conclusion, identifier=1, status="completed", app="github-actions"):
    return {"id": identifier, "name": name, "status": status,
            "conclusion": conclusion, "app": {"slug": app}}


class PRCIStatusTests(unittest.TestCase):
    def test_reviewer_pass_does_not_hide_failed_source_or_cancelled_native(self):
        report = MODULE.summarize([
            check("cubic · AI code reviewer", "success", app="cubic-dev-ai"),
            check("swift", "failure"), check("app-acceptance", "cancelled"),
        ])
        self.assertEqual(report["state"], "failed")

    def test_failure_takes_precedence_over_another_pending_gate(self):
        report = MODULE.summarize([
            check("swift", "failure"), check("app-acceptance", None, status="queued"),
        ])
        self.assertEqual(report["state"], "failed")

    def test_only_reviewer_or_one_pass_is_still_pending(self):
        for checks in ([check("reviewer", "success")], [check("swift", "success")]):
            self.assertEqual(MODULE.summarize(checks)["state"], "pending")

    def test_both_gates_must_pass_and_latest_attempt_wins(self):
        checks = [check("swift", "failure", 1), check("swift", "success", 3),
                  check("app-acceptance", "success", 2)]
        self.assertEqual(MODULE.summarize(checks)["state"], "passed")
        checks.append(check("swift", "failure", 4))
        self.assertEqual(MODULE.summarize(checks)["state"], "failed")
