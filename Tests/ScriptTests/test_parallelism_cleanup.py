"""An interrupted experiment must retire the detached trial it owns."""
import os
import select
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ParallelismCleanupTests(unittest.TestCase):
    def test_interrupt_stops_the_detached_trial(self):
        with tempfile.TemporaryDirectory(prefix="downright-compare-interrupt-") as temporary:
            directory = Path(temporary)
            tools = directory / "bin"
            tools.mkdir()
            worker_pid = directory / "worker.pid"
            os.mkfifo(worker_pid)
            swift = tools / "swift"
            swift.write_text(f"#!{sys.executable}\n" +
                             "import os, pathlib, signal, sys\n"
                             "if sys.argv[1] == 'build': sys.exit(0)\n"
                             "pathlib.Path(os.environ['TRIAL_PID_FILE']).write_text(str(os.getpid()))\n"
                             "signal.pause()\n")
            swift.chmod(0o755)
            xcode_select = tools / "xcode-select"
            xcode_select.write_text("#!/bin/sh\necho /Applications/Xcode.app/Contents/Developer\n")
            xcode_select.chmod(0o755)
            environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ.get("PATH", ""),
                               TRIAL_PID_FILE=str(worker_pid), PYTHONDONTWRITEBYTECODE="1")
            environment.pop("TEST_SCRATCH", None)
            # Keep the reader open before starting the subprocess. Its PID
            # write is the readiness signal, so send SIGINT only after that.
            ready = os.open(worker_pid, os.O_RDWR | os.O_NONBLOCK)
            process = subprocess.Popen(
                [sys.executable, "-B", str(ROOT / "Scripts/compare-test-parallelism.py"),
                 "--scratch-path", str(directory / "build"), "--output", str(directory / "evidence"),
                 "--repeats", "1"], cwd=ROOT, env=environment,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
            pid = None
            try:
                readable, _, _ = select.select([ready], [], [], 10)
                self.assertTrue(readable, "the fixture trial did not start")
                pid = int(os.read(ready, 128))
                process.send_signal(signal.SIGINT)
                process.communicate(timeout=10)
                self.assertNotEqual(process.returncode, 0)
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
            finally:
                os.close(ready)
                if process.poll() is None:
                    process.kill()
                    process.communicate()
                if pid is not None:
                    try:
                        os.killpg(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    unittest.main()
