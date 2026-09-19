"""Prove a universal app cannot silently ship a thin nested executable."""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "requires Mach-O toolchain")
class BundleArchitectureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="downright-architectures-")
        cls.root = pathlib.Path(cls.directory.name)
        source = cls.root / "main.c"
        source.write_text("int main(void) { return 0; }\n")
        for arch in ("arm64", "x86_64"):
            subprocess.run(["xcrun", "clang", "-arch", arch, str(source), "-o", str(cls.root / arch)], check=True)
        subprocess.run(["lipo", "-create", str(cls.root / "arm64"), str(cls.root / "x86_64"), "-output", str(cls.root / "universal")], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def verify(self, host, child):
        with tempfile.TemporaryDirectory(dir=self.root) as temporary:
            app = pathlib.Path(temporary) / "An App.app"
            macos = app / "Contents" / "MacOS"
            macos.mkdir(parents=True)
            shutil.copy2(self.root / host, macos / "Downright")
            shutil.copy2(self.root / child, macos / "down")
            (macos / "readme.txt").write_text("non-executable resource")
            return subprocess.run([str(ROOT / "Scripts/verify-bundle-architectures.sh"), str(app)], text=True, capture_output=True)

    def test_universal_host_rejects_thin_helper(self):
        result = self.verify("universal", "arm64")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing x86_64", result.stderr)

    def test_universal_host_accepts_universal_helper(self):
        self.assertEqual(self.verify("universal", "universal").returncode, 0)

    def test_thin_development_host_accepts_matching_helper(self):
        self.assertEqual(self.verify("arm64", "arm64").returncode, 0)
