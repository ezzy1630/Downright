import importlib.util
from pathlib import Path
import unittest
import subprocess
import sys
import tempfile


MODULE = Path(__file__).resolve().parents[2] / "Scripts/sample-test-processes.py"
SPEC = importlib.util.spec_from_file_location("test_process_diagnostics", MODULE)
DIAGNOSTICS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DIAGNOSTICS)


class TestProcessDiagnosticsTests(unittest.TestCase):
    def test_collects_only_descendants_of_the_gate(self):
        table = """
        10 1 00:10 0.0 /bin/bash
        11 10 00:09 0.1 /Applications/Xcode 26.app/usr/bin/swift-test
        12 11 00:08 0.0 /tmp/build/DownrightAppTests
        20 1 01:00 0.0 /other/session/DownrightAppTests
        21 20 00:50 0.0 /other/session/swiftpm-testing
        """
        processes = DIAGNOSTICS.descendant_processes(table, 10)
        self.assertEqual(set(processes), {11, 12})
        self.assertEqual(processes[11][3], "/Applications/Xcode 26.app/usr/bin/swift-test")

    def test_process_order_does_not_hide_grandchildren(self):
        table = """
        12 11 00:08 0.0 /tmp/DownrightAppTests
        11 10 00:09 0.1 /usr/bin/swift-test
        10 1 00:10 0.0 /bin/bash
        """
        self.assertEqual(set(DIAGNOSTICS.descendant_processes(table, 10)), {11, 12})
        self.assertEqual(DIAGNOSTICS.descendant_processes(table, 99), {})

    def test_orphaned_watcher_does_not_collect_process_data(self):
        with tempfile.TemporaryDirectory() as folder:
            result = subprocess.run(
                [sys.executable, str(MODULE), "--parent-pid", "99999999",
                 "--delay-seconds", "0", "--output-prefix", str(Path(folder) / "probe")],
                capture_output=True, text=True, timeout=5,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertEqual(list(Path(folder).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
