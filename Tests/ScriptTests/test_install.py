import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "Scripts"
        scripts.mkdir()
        repository = Path(__file__).resolve().parents[2]
        shutil.copy2(repository / "Scripts/install.sh", scripts / "install.sh")
        self.script = scripts / "install.sh"
        self.write_executable(scripts / "verify-bundle.sh", "exit 0\n")
        self.fake_bin = self.root / "fake-bin"
        self.fake_bin.mkdir()
        self.write_executable(self.fake_bin / "pgrep", "exit 1\n")
        self.write_executable(self.fake_bin / "codesign", 'exit "${FAKE_CODESIGN_STATUS:-0}"\n')
        for command in ["qlmanage", "pluginkit", "md"]:
            self.write_executable(self.fake_bin / command, "exit 0\n")
        self.source = self.root / "candidate.app"
        (self.source / "Contents/MacOS").mkdir(parents=True)
        self.write_executable(self.source / "Contents/MacOS/Downright", "exit 0\n")
        self.write_executable(self.source / "Contents/MacOS/down", "exit 0\n")
        (self.source / "generation").write_text("new")
        applications = self.root / "Applications"
        applications.mkdir()
        self.destination = applications / "Downright.app"
        self.destination.mkdir()
        (self.destination / "generation").write_text("old")
        self.bin_destination = self.root / "bin"

    @staticmethod
    def write_executable(path, body):
        path.write_text("#!/bin/bash\n" + body)
        path.chmod(0o755)

    def install(self, **overrides):
        environment = dict(os.environ)
        environment.pop("STAGED_APP", None)
        environment.update(
            APP_SOURCE=str(self.source),
            APP_DEST=str(self.destination),
            BIN_DEST=str(self.bin_destination),
            PATH=f"{self.fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin",
            **overrides,
        )
        return subprocess.run(
            ["/bin/bash", str(self.script)], env=environment,
            capture_output=True, text=True, timeout=10,
        )

    def assert_no_staging_directories(self):
        self.assertEqual(list(self.destination.parent.glob(".downright-*")), [])

    def test_installs_the_verified_candidate_and_links_its_cli(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.destination / "generation").read_text(), "new")
        self.assertEqual(
            os.readlink(self.bin_destination / "down"),
            str(self.destination / "Contents/MacOS/down"),
        )
        self.assert_no_staging_directories()

    def test_failed_staged_signature_keeps_the_installed_app(self):
        result = self.install(FAKE_CODESIGN_STATUS="1")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.destination / "generation").read_text(), "old")
        self.assert_no_staging_directories()

    def test_failed_swap_restores_the_installed_app(self):
        self.write_executable(
            self.fake_bin / "mv",
            'case "$1" in */.downright-install.*/Downright.app) exit 1;; esac\n'
            'exec /bin/mv "$@"\n',
        )
        result = self.install()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.destination / "generation").read_text(), "old")
        self.assert_no_staging_directories()


if __name__ == "__main__":
    unittest.main()
