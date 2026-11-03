"""Coverage and exit-status evidence must survive failures and duplicate output."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/ci-report.py"
SPEC = importlib.util.spec_from_file_location("ci_report", SCRIPT)
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)


class CoverageTests(unittest.TestCase):
    def test_multiple_raw_swift_targets_are_summed(self):
        first = "✔ Test run with 12 tests in 2 suites passed after 1.25 seconds.\n"
        second = "✔ Test run with 4 tests passed after 2.50 seconds.\n"
        result = REPORT.coverage(first + second)
        self.assertEqual(result["executed"], 16)
        self.assertEqual(result["execution_seconds"], 3.75)

    def test_equal_counts_and_durations_can_be_distinct_runs(self):
        text = "✔ Test run with 4 tests passed after 0.100 seconds.\n"
        result = REPORT.coverage(text + text)
        self.assertEqual(result["executed"], 8)
        self.assertEqual(result["execution_seconds"], 0.2)

    def test_disabled_window_coverage_is_skipped_not_passed(self):
        text = '➜ Test "10k-line typing and scrolling" skipped: "Requires a window server"\n'
        result = REPORT.coverage(text + "✔ Test run with 3 tests passed after 0.1 seconds.\n")
        self.assertEqual(result["executed"], 3)
        self.assertEqual(result["skipped"], 1)
        self.assertEqual(result["real_window_performance"], "not executed")

    def test_xcode_aggregate_is_not_added_to_per_suite_totals(self):
        result = REPORT.coverage("Executed 10 tests, with 1 test skipped and 0 failures\n"
                                 "Executed 11 tests, with 0 failures\n"
                                 "Executed 21 tests, with 1 test skipped and 0 failures\n")
        self.assertEqual(result["executed"], 20)
        self.assertEqual(result["skipped"], 1)

    def test_no_output_is_unavailable_not_zero_tests_passed(self):
        self.assertIsNone(REPORT.coverage("")["executed"])


class CheckRunnerTests(unittest.TestCase):
    def run_check(self, program, stale_log=False):
        with tempfile.TemporaryDirectory(prefix="downright-report-test-") as temporary:
            output = Path(temporary)
            if stale_log:
                (output / "tmp").mkdir()
                (output / "tmp/downright-test-old.log").write_text("✔ Test run with 999 tests passed after 0.1 seconds.\n")
            result = subprocess.run([sys.executable, "-B", str(SCRIPT), "--name", "regression",
                                     "--output", str(output), "--require-tests", "--",
                                     sys.executable, "-c", program], cwd=ROOT,
                                    env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"),
                                    capture_output=True, text=True, timeout=30)
            report = json.loads((output / "results.json").read_text())
            self.assertTrue((output / "run.log").exists())
            self.assertTrue((output / "summary.md").exists())
            return result, report, (output / "run.log").read_text()

    def test_failure_status_and_partial_logs_are_preserved(self):
        result, report, log = self.run_check("print('==> Tests'); print('assertion failed'); raise SystemExit(42)")
        self.assertEqual(result.returncode, 42)
        self.assertEqual(report["exit_status"], 42)
        self.assertEqual(report["phases"][0]["name"], "Tests")
        self.assertIn("assertion failed", log)

    def test_successful_command_without_required_tests_fails(self):
        result, report, _ = self.run_check("print('build succeeded')")
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(report["coverage"]["executed"])

    def test_stale_logs_cannot_satisfy_required_execution(self):
        result, report, _ = self.run_check("print('build succeeded')", stale_log=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(report["coverage"]["executed"])

    def test_real_execution_evidence_passes(self):
        result, report, _ = self.run_check("print('✔ Test run with 2 tests passed after 0.01 seconds.')")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report["coverage"]["executed"], 2)


if __name__ == "__main__":
    unittest.main()
