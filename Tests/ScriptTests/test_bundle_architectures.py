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
        """A nested binary reachable only as a symlink must not escape the gate.

        The target is stored *outside* the bundle on purpose. If it lived under
        Contents as a regular file, a plain `-type f` walk would find the thin
        binary directly and this test would stay green even if symlink handling
        regressed — proving nothing about the behaviour it is named for.
        """
        with tempfile.TemporaryDirectory(dir=self.root) as temporary:
            outside = pathlib.Path(temporary) / "outside-the-bundle"
            outside.mkdir()
            shutil.copy2(self.root / "arm64-helper", outside / "real-helper")
            app = pathlib.Path(temporary) / "An App.app"
            macos = app / "Contents" / "MacOS"
            macos.mkdir(parents=True)
            shutil.copy2(self.root / "universal-host", macos / "Downright")
            (macos / "down").symlink_to(outside / "real-helper")
            result = subprocess.run(
                [str(ROOT / "Scripts/verify-bundle-architectures.sh"), str(app)],
                text=True, capture_output=True, timeout=TIMEOUT)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing x86_64", result.stderr)

    def test_a_symlinked_directory_is_not_descended(self):
        """Following symlinked directories would make the verdict depend on
        files outside the bundle (and could spin on a loop). A symlink *to a
        directory* holding a thin binary must therefore not be walked into."""
        with tempfile.TemporaryDirectory(dir=self.root) as temporary:
            outside = pathlib.Path(temporary) / "outside-the-bundle"
            outside.mkdir()
            shutil.copy2(self.root / "arm64-helper", outside / "stranger")
            app = pathlib.Path(temporary) / "An App.app"
            macos = app / "Contents" / "MacOS"
            macos.mkdir(parents=True)
            shutil.copy2(self.root / "universal-host", macos / "Downright")
            (app / "Contents" / "Elsewhere").symlink_to(outside, target_is_directory=True)
            result = subprocess.run(
                [str(ROOT / "Scripts/verify-bundle-architectures.sh"), str(app)],
                text=True, capture_output=True, timeout=TIMEOUT)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_symlink_loop_does_not_hang_or_pass_silently(self):
        """A loop must not be walked into, and must not leave the gate
        reporting success having enumerated nothing."""
        with tempfile.TemporaryDirectory(dir=self.root) as temporary:
            app = pathlib.Path(temporary) / "An App.app"
            macos = app / "Contents" / "MacOS"
            macos.mkdir(parents=True)
            shutil.copy2(self.root / "universal-host", macos / "Downright")
            shutil.copy2(self.root / "arm64-helper", macos / "down")
            (app / "Contents" / "Loop").symlink_to(app / "Contents", target_is_directory=True)
            result = subprocess.run(
                [str(ROOT / "Scripts/verify-bundle-architectures.sh"), str(app)],
                text=True, capture_output=True, timeout=TIMEOUT)
            # The real thin helper is still caught; the loop neither hangs nor
            # swallows the verdict.
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
