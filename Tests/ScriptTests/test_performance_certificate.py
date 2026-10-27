"""Keep a partial or rounded performance result from becoming a certificate."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/certify-performance.py"
CASES = [
    ("cmark alone", 15), ("MarkdownParser.parse, all passes", 15),
    ("ASTDiff.dirtySet, one-character edit", 25), ("TextDiff.hunks, external rewrite", 10),
    ("incremental, one dirty block", 25), ("wholesale (mode switch)", 5),
    ("edit + paragraph map", 100), ("worker pipeline", 60),
    ("parse 100 KB", 30), ("syntax highlight 10 KB Swift", 20),
]


class PerformanceCertificateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.baseline = self.root / "baseline.log"
        self.candidate = self.root / "candidate.log"
        self.baseline.write_text(self.log(10))
        self.candidate.write_text(self.log(7))
        self.memories = []
        for pid in [101, 102, 103]:
            path = self.root / f"memory-{pid}.json"
            path.write_text(json.dumps(dict(
                pid=pid, artifact_sha256="a" * 64,
                source_sha256_before="b" * 64, source_sha256_after="b" * 64,
                completed_actions=["open", "edit-save-undo-save", "scroll", "mode-cycles"],
                peak_physical_mib=120,
            )))
            self.memories.append(path)

    def log(self, p95, cases=CASES):
        return "build: release\ncorpus: 120825 chars, 4885 lines\ncold-open corpus: 100000 chars\n" + "\n".join(
            f"  {label}  p50 {p95:.3f} ms   p95 {p95:.3f} ms   max {p95:.3f} ms (n={count})"
            for label, count in cases)

    def run_check(self, full=True):
        args = [sys.executable, str(SCRIPT), "--baseline", str(self.baseline), "--candidate", str(self.candidate)]
        if full:
            for path in self.memories:
                args += ["--memory", str(path)]
        else:
            args += ["--timings-only"]
        return subprocess.run(args, capture_output=True, text=True, timeout=5)

    def test_all_timings_and_three_complete_sessions_pass(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(result.stdout.count("| PASS |"), 10)

    def test_one_timing_miss_cannot_hide_behind_other_improvements(self):
        self.candidate.write_text(self.log(7).replace("p95 7.000 ms", "p95 8.000 ms", 1))
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_rounding_does_not_overclaim_the_exact_boundary(self):
        self.candidate.write_text(self.log(7.5))
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_peak_must_be_strictly_below_150(self):
        record = json.loads(self.memories[0].read_text())
        record["peak_physical_mib"] = 150_000_000 / 2**20
        self.memories[0].write_text(json.dumps(record))
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_missing_case_or_changed_sample_count_fails(self):
        self.candidate.write_text(self.log(7, CASES[:-1]))
        self.assertNotEqual(self.run_check().returncode, 0)
        changed = CASES.copy()
        changed[0] = (changed[0][0], 1)
        self.candidate.write_text(self.log(7, changed))
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_memory_requires_distinct_processes_and_restored_bytes(self):
        record = json.loads(self.memories[0].read_text())
        self.memories[1].write_text(json.dumps(record))
        self.assertNotEqual(self.run_check().returncode, 0)
        record["pid"] = 102
        record["source_sha256_after"] = "c" * 64
        self.memories[1].write_text(json.dumps(record))
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_timings_only_explicitly_leave_memory_uncertified(self):
        result = self.run_check(full=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("native memory is not certified", result.stdout)


if __name__ == "__main__":
    unittest.main()
