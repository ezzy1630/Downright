"""Exercise source-gate orchestration without compiling the app for each case."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]


class SourceGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for directory in ("Scripts", "Tests", "Sources/DownrightApp/Updater", "bin"):
            (self.root / directory).mkdir(parents=True)
        shutil.copy2(REPOSITORY / "Scripts/check.sh", self.root / "Scripts/check.sh")
        (self.root / "Sources/DownrightApp/Updater/Updater.swift").write_text("import Sparkle\n")
        (self.root / "Tests/KnownIssues.swift").write_text("withKnownIssue(\nwithKnownIssue(\n")
        self.executable("Scripts/sync-versions.sh", '#!/bin/bash\nexit "${VERSION_STATUS:-0}"\n')
        self.executable("bin/python3", "#!/bin/bash\ncat >/dev/null\nexit 0\n")
        self.executable("bin/xcode-select", "#!/bin/bash\necho /Applications/Xcode.app/Contents/Developer\n")
        self.executable("bin/swift", f"#!{sys.executable}\n" + '''
import json
import os
import sys
with open(os.environ["SWIFT_CALLS"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
command = sys.argv[1]
if command == "test" and os.environ.get("ZERO_TESTS") != "1":
    print("✔ Test example() passed after 0.001 seconds.")
    print("✔ Test run with 1 test passed after 0.001 seconds.")
elif command == "run":
    print("Typing response p95: 1 ms")
sys.exit(int(os.environ.get(command.upper() + "_STATUS", "0")))
''')
        if ripgrep := shutil.which("rg"):
            (self.root / "bin/rg").symlink_to(ripgrep)
        self.environment = dict(os.environ)
        for key in ("TEST_SCRATCH", "BENCH_SCRATCH", "DOWNRIGHT_SUPPORT_DIRECTORY", "RUN_DRBENCH"):
            self.environment.pop(key, None)
        self.environment.update(
            PATH=f"{self.root / 'bin'}:/usr/bin:/bin:/usr/sbin:/sbin",
            SCRATCH=".build-gate", TMPDIR=str(self.root), CI="false",
            SWIFT_CALLS=str(self.root / "swift-calls.jsonl"),
        )

    def executable(self, relative_path, contents):
        path = self.root / relative_path
        path.write_text(contents)
        path.chmod(0o755)

    def run_gate(self, **overrides):
        result = subprocess.run(
            ["/bin/bash", str(self.root / "Scripts/check.sh")],
            env=dict(self.environment, **overrides), capture_output=True, text=True, timeout=10,
        )
        calls_path = Path(self.environment["SWIFT_CALLS"])
        calls = [json.loads(line) for line in calls_path.read_text().splitlines()] if calls_path.exists() else []
        return result, calls

    def test_debug_build_and_tests_share_modules_and_run_one_benchmark(self):
        result, calls = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        debug_calls = [call for call in calls if call[0] in ("build", "test")]
        self.assertGreaterEqual(len(debug_calls), 2)
        self.assertTrue(all(call[call.index("--scratch-path") + 1] == ".build-gate" for call in debug_calls))
        benchmarks = [call for call in calls if call[0] == "run"]
        self.assertEqual(len(benchmarks), 1)
        self.assertNotIn("release", benchmarks[0])

    def test_release_budget_replaces_debug_benchmark(self):
        result, calls = self.run_gate(RUN_DRBENCH="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        benchmarks = [call for call in calls if call[0] == "run"]
        self.assertEqual(len(benchmarks), 1)
        self.assertIn("release", benchmarks[0])
        self.assertIn(".build-gate-bench", benchmarks[0])

    def test_explicit_benchmark_scratch_is_preserved(self):
        result, calls = self.run_gate(RUN_DRBENCH="1", BENCH_SCRATCH=".build-isolated-benchmark")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        benchmark = next(call for call in calls if call[0] == "run")
        self.assertEqual(benchmark[benchmark.index("--scratch-path") + 1], ".build-isolated-benchmark")

    def test_explicit_test_scratch_is_preserved(self):
        result, calls = self.run_gate(TEST_SCRATCH=".build-isolated-tests")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        tests = next(call for call in calls if call[0] == "test")
        self.assertEqual(tests[tests.index("--scratch-path") + 1], ".build-isolated-tests")

    def test_clt_framework_flags_keep_tests_in_a_separate_graph(self):
        frameworks = self.root / "clt-frameworks"
        (frameworks / "Testing.framework").mkdir(parents=True)
        script = self.root / "Scripts/check.sh"
        script.write_text(script.read_text().replace(
            "/Library/Developer/CommandLineTools/Library/Developer/Frameworks", str(frameworks),
        ))
        self.executable("bin/xcode-select", "#!/bin/bash\necho /Library/Developer/CommandLineTools\n")
        result, calls = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        tests = next(call for call in calls if call[0] == "test")
        self.assertEqual(tests[tests.index("--scratch-path") + 1], ".build-gate-test")
        self.assertIn(str(frameworks), tests)
        self.assertIn("-Xswiftc", tests)

    def test_test_failure_survives_ci_tee_and_never_runs_benchmarks(self):
        result, calls = self.run_gate(CI="true", TEST_STATUS="42", RUN_DRBENCH="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TESTS FAILED", result.stdout)
        self.assertFalse(any(call[0] == "run" for call in calls))

    def test_success_with_zero_tests_is_rejected(self):
        result, calls = self.run_gate(ZERO_TESTS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NO TESTS RAN", result.stdout)
        self.assertFalse(any(call[0] == "run" for call in calls))

    def test_release_budget_failure_is_rejected(self):
        result, _ = self.run_gate(RUN_DRBENCH="1", RUN_STATUS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("performance budget was violated", result.stdout)

    def test_known_issue_inventory_counts_swift_sites_and_ignores_script_fixtures(self):
        (self.root / "Tests/fixture.py").write_text('fixture = "withKnownIssue("\n')
        result, _ = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("2 deliberate known-issue sites", result.stdout)
        (self.root / "Tests/Unexpected.swift").write_text("withKnownIssue(\n")
        result, _ = self.run_gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("KNOWN-ISSUE GATE FAILED", result.stdout)


class ToolchainSelectionTests(unittest.TestCase):
    def test_stops_after_the_first_compatible_xcode(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "Scripts").mkdir()
            (root / "bin").mkdir()
            for name in ("Selected.app", "Unused.app"):
                (root / name / "Contents/Developer").mkdir(parents=True)
            (root / "Package.swift").write_text("// swift-tools-version: 6.0\n")
            shutil.copy2(REPOSITORY / "Scripts/select-toolchain.sh", root / "Scripts/select-toolchain.sh")
            commands = {
                "xcode-select": f'echo "{root}/Selected.app/Contents/Developer"\n',
                "ls": f'echo "{root}/Unused.app"\n',
                "swift": 'echo "$DEVELOPER_DIR $*" >> "$TOOLCHAIN_CALLS"\n'
                         'if [ "$1" = "--version" ]; then echo "Apple Swift version 6.0"; fi\n',
            }
            for name, body in commands.items():
                path = root / "bin" / name
                path.write_text("#!/bin/bash\n" + body)
                path.chmod(0o755)
            result = subprocess.run(
                ["/bin/bash", str(root / "Scripts/select-toolchain.sh")],
                env=dict(os.environ, PATH=f"{root}/bin:/usr/bin:/bin", GITHUB_ENV=str(root / "github-env"),
                         TOOLCHAIN_CALLS=str(root / "calls")),
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            calls = (root / "calls").read_text().splitlines()
            self.assertEqual(len(calls), 2)  # Selected compiler version, then the manifest proof.
            self.assertTrue(all("Selected.app" in line for line in calls))
            self.assertIn("package dump-package", calls[-1])
            self.assertIn("Selected.app/Contents/Developer", (root / "github-env").read_text())


if __name__ == "__main__":
    unittest.main()
