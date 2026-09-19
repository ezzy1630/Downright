"""Prove a universal app cannot silently ship a thin nested executable."""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
# Every subprocess is bounded. The script under test walks a bundle tree, so a
# regression that loops would otherwise hang the gate instead of failing it.
TIMEOUT = 60


@unittest.skipUnless(sys.platform == "darwin", "requires Mach-O toolchain")
class BundleArchitectureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="downright-architectures-")
        # Registered before anything can fail, so a compile error still removes
        # the partial artifacts rather than leaking the temporary directory.
        cls.addClassCleanup(cls.directory.cleanup)
        cls.root = pathlib.Path(cls.directory.name)
        source = cls.root / "main.c"
        source.write_text("int main(void) { return 0; }\n")
        for arch in ("arm64", "x86_64"):
            # A distinct binary per slice, so the "matching thin" case cannot
            # pass by handing the checker the very same file twice.
            for copy in ("host", "helper"):
                subprocess.run(
                    ["xcrun", "clang", "-arch", arch, str(source),
                     "-o", str(cls.root / f"{arch}-{copy}")],
                    check=True, timeout=TIMEOUT)
        subprocess.run(
            ["lipo", "-create", str(cls.root / "arm64-host"), str(cls.root / "x86_64-host"),
             "-output", str(cls.root / "universal-host")], check=True, timeout=TIMEOUT)
        subprocess.run(
            ["lipo", "-create", str(cls.root / "arm64-helper"), str(cls.root / "x86_64-helper"),
             "-output", str(cls.root / "universal-helper")], check=True, timeout=TIMEOUT)

    def verify(self, host, child):
        with tempfile.TemporaryDirectory(dir=self.root) as temporary:
            app = pathlib.Path(temporary) / "An App.app"
            macos = app / "Contents" / "MacOS"
            macos.mkdir(parents=True)
            shutil.copy2(self.root / host, macos / "Downright")
            shutil.copy2(self.root / child, macos / "down")
            (macos / "readme.txt").write_text("non-executable resource")
            return subprocess.run(
                [str(ROOT / "Scripts/verify-bundle-architectures.sh"), str(app)],
                text=True, capture_output=True, timeout=TIMEOUT)

    def test_universal_host_rejects_thin_arm64_helper(self):
        result = self.verify("universal-host", "arm64-helper")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing x86_64", result.stderr)

    def test_universal_host_rejects_thin_x86_64_helper(self):
        result = self.verify("universal-host", "x86_64-helper")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing arm64", result.stderr)

    def test_universal_host_accepts_universal_helper(self):
        result = self.verify("universal-host", "universal-helper")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_thin_development_host_accepts_matching_helper(self):
        result = self.verify("arm64-host", "arm64-helper")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_symlinked_helper_is_still_verified(self):
        """`find -type f` skips symlinks; a nested binary must not escape that way."""
        with tempfile.TemporaryDirectory(dir=self.root) as temporary:
            app = pathlib.Path(temporary) / "An App.app"
            macos = app / "Contents" / "MacOS"
            macos.mkdir(parents=True)
            shutil.copy2(self.root / "universal-host", macos / "Downright")
            shutil.copy2(self.root / "arm64-helper", app / "Contents" / "real-helper")
            (macos / "down").symlink_to("../real-helper")
            result = subprocess.run(
                [str(ROOT / "Scripts/verify-bundle-architectures.sh"), str(app)],
                text=True, capture_output=True, timeout=TIMEOUT)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing x86_64", result.stderr)

    def test_a_missing_host_executable_fails_loudly(self):
        with tempfile.TemporaryDirectory(dir=self.root) as temporary:
            app = pathlib.Path(temporary) / "Empty.app"
            (app / "Contents" / "MacOS").mkdir(parents=True)
            result = subprocess.run(
                [str(ROOT / "Scripts/verify-bundle-architectures.sh"), str(app)],
                text=True, capture_output=True, timeout=TIMEOUT)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("cannot read host architectures", result.stderr)
