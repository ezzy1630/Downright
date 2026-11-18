"""Exercise the honesty rules against representative source and ratchet changes."""
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import textwrap
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/lint-tests.py"
LINT = runpy.run_path(str(SCRIPT))


class TestHonestyLintTests(unittest.TestCase):
    def violations(self, language, source):
        return sorted(LINT[f"{language}_violations"](textwrap.dedent(source).strip()))

    def test_swift_waits_are_calls_not_fixture_text(self):
        findings = self.violations("swift", '''
            // Thread.sleep(forTimeInterval: 1)
            /* nested /* Task.sleep(for: .seconds(1)) */ comment */
            let fixture = #"use sleep(2) and "quoted" source"#
            let escaped = "literal \\"Thread.sleep(forTimeInterval: 1)\\" example"
            let multi = """
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {}
            """
            func sleep(_ number: Int) {}
            Thread.sleep(forTimeInterval: 1)
            try await Task<Void, Never>.sleep(for: .seconds(1))
            Darwin.usleep(10)
            sleep(1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {}
            RunLoop.main.run(
                until: Date().addingTimeInterval(0.1))
            await fulfillment(of: [completed], timeout: 5)
        ''')
        self.assertEqual(findings, [(line, "fixed-wait") for line in range(9, 15)])

    def test_uninterpolated_values_in_fixture_paths(self):
        findings = self.violations("swift", '''
            let shared = temp.appendingPathComponent("fixture-(UUID().uuidString)")
            let unique = temp.appendingPathComponent("fixture-\\(UUID().uuidString)")
            let raw = #"stamp-\\#(Date().timeIntervalSince1970)"#
            let prose = "Call it (later) when ready"
            // "fixture-(UUID().uuidString)" in a comment is not code
        ''')
        self.assertEqual(findings, [(1, "missing-interpolation")])

    def test_known_issue_needs_reason_and_tracking_link(self):
        findings = self.violations("swift", '''
            withKnownIssue("Dependency draws only on screen — https://example.org/issues/47") {}
            withKnownIssue("Untracked render mismatch") {}
            withKnownIssue("https://example.org/issues/47") {}
            withKnownIssue(isIntermittent: true) {}
            @Test(.timeLimit(.minutes(10)))
        ''')
        self.assertEqual(findings, [(2, "known-issue"), (3, "known-issue"),
                                    (4, "known-issue"), (5, "time-limit")])

    def test_retry_and_behavior_replacement_with_observer_and_table_cases(self):
        findings = self.violations("swift", '''
            struct FakeRenderer: RenderProtocol { func render() -> String { "expected" } }
            struct RecordingObserver: RenderObserver { func didRender(_ value: String) { values.append(value) } }
            for entry in fixtures { #expect(render(entry.input) == entry.output) }
            for attempt in 0..<3 {
                do { try #require(render() == expected); break }
                catch { continue }
            }
            for _ in 0..<3 { do { try #require(render() == expected) } catch {} }
            final class MockObserver: Observer {
                override func didRender() { calls += 1; super.didRender() }
                func record() -> Void { calls += 1 }
            }
        ''')
        self.assertEqual(findings, [(1, "test-double"), (4, "assertion-retry"), (8, "assertion-retry")])

    def test_python_aliases_assertion_retries_and_fixtures(self):
        findings = self.violations("python", '''
            import time as clock
            from asyncio import sleep as pause
            def wait(self):
                fixture = "time.sleep(10)"
                clock.sleep(1)
                awaitable = pause(1)
                for case in fixtures:
                    self.assertEqual(case.actual(), case.expected)
                for attempt in range(3):
                    try:
                        self.assertEqual(observe(), expected)
                    except AssertionError:
                        continue
            class StubReader(Reader):
                def read(self): return "expected"
            class RecordingObserver(Observer):
                def on_read(self, value): self.values.append(value)
        ''')
        self.assertEqual(findings, [(5, "fixed-wait"), (6, "fixed-wait"),
                                    (9, "assertion-retry"), (14, "test-double")])

    def test_python_retry_through_superclass_or_bare_handlers(self):
        findings = self.violations("python", '''
            for attempt in range(3):
                try:
                    self.assertEqual(observe(), expected)
                except Exception:
                    continue
            while True:
                try:
                    assert observe() == expected
                    break
                except (ValueError, BaseException):
                    pass
            for attempt in range(3):
                try:
                    self.assertTrue(observe())
                except:
                    continue
            for attempt in range(3):
                try:
                    self.assertTrue(observe())
                except ValueError:
                    continue
        ''')
        self.assertEqual(findings, [(1, "assertion-retry"), (6, "assertion-retry"), (12, "assertion-retry")])

    def test_allowlist_fails_above_below_and_after_file_removal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Scripts").mkdir()
            (root / "Tests").mkdir()
            (root / "Scripts/lint-tests.py").write_bytes(SCRIPT.read_bytes())
            test_path = root / "Tests/Example.swift"
            allowance = root / "Scripts/test-lint-allowlist.json"
            allowance.write_text(json.dumps({"Tests/Example.swift": {"fixed-wait": 1}}))

            def lint():
                return subprocess.run(
                    [sys.executable, str(root / "Scripts/lint-tests.py")],
                    capture_output=True, text=True, check=False,
                )

            test_path.write_text("Task.sleep(for: .seconds(1))\n")
            self.assertEqual(lint().returncode, 0)
            test_path.write_text("Task.sleep(for: .seconds(1))\nusleep(50)\n")
            result = lint()
            self.assertEqual(result.returncode, 1)
            self.assertIn("Example.swift:2", result.stderr)
            self.assertIn("Wait for a completion", result.stderr)
            test_path.unlink()
            result = lint()
            self.assertEqual(result.returncode, 1)
            self.assertIn("Lower the allowance to 0", result.stderr)
