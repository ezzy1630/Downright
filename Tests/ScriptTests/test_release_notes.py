"""Exercise the release-note command with real changelogs and Git history."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/release-notes.py"


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(
            ["git", "-c", "user.name=Release Test", "-c", "user.email=release@example.invalid",
             "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "Fixture maintenance change"],
            cwd=self.root, check=True,
        )
        self.changelog = self.root / "CHANGELOG.md"

    def generate(self, text, previous_tag=""):
        if text is not None:
            self.changelog.write_text(text)
        return subprocess.run(
            [sys.executable, str(SCRIPT), "1.0.17", "343", "ezzy1630/Downright",
             "--changelog", str(self.changelog), "--previous-tag", previous_tag],
            cwd=self.root, capture_output=True, text=True, timeout=10,
        )

    def test_uses_only_the_matching_version_and_preserves_markdown(self):
        result = self.generate("""# Changelog
## [Unreleased]
- Future work.
## [1.0.17] - 2026-10-27
### Fixed
- **Local links** open in Downright. See [help](https://example.com/help).
## Earlier rolling releases
- Old work.
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("# Downright 1.0.17 (build 343)", result.stdout)
        self.assertIn("### Fixed\n- **Local links**", result.stdout)
        self.assertIn("[help](https://example.com/help)", result.stdout)
        for excluded in ["Future work", "Old work", "Fixture maintenance change"]:
            self.assertNotIn(excluded, result.stdout)

    def test_headings_inside_fences_do_not_end_the_version(self):
        result = self.generate("## [1.0.17]\nExample:\n```markdown\n## Example\n```\n- Kept after example.\n## [1.0.0]\nOld.\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("## Example\n```\n- Kept after example.", result.stdout)
        self.assertNotIn("Old.", result.stdout)

    def test_unlisted_version_falls_back_to_real_commit_history(self):
        result = self.generate("## [Unreleased]\nFuture.\n## [1.0.0]\nOld.\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("## What's new", result.stdout)
        self.assertIn("Fixture maintenance change", result.stdout)
        self.assertNotIn("Future.", result.stdout)
        self.assertNotIn("Old.", result.stdout)

    def test_history_fallback_excludes_the_previous_release(self):
        subprocess.run(["git", "tag", "auto-baseline"], cwd=self.root, check=True)
        subprocess.run(
            ["git", "-c", "user.name=Release Test", "-c", "user.email=release@example.invalid",
             "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "Only the new fix"],
            cwd=self.root, check=True,
        )
        result = self.generate("## [Unreleased]\nFuture.\n", previous_tag="auto-baseline")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Only the new fix", result.stdout)
        self.assertNotIn("Fixture maintenance change", result.stdout)

    def test_empty_history_is_rejected_instead_of_publishing_a_header(self):
        subprocess.run(["git", "tag", "auto-current"], cwd=self.root, check=True)
        result = self.generate("## [Unreleased]\nFuture.\n", previous_tag="auto-current")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no commits", result.stderr)
        self.assertNotIn("# Downright", result.stdout)

    def test_history_failure_is_not_published_as_successful_notes(self):
        result = self.generate("## [Unreleased]\nFuture.\n", previous_tag="missing-tag")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release-notes:", result.stderr)
        self.assertNotIn("# Downright", result.stdout)

    def test_empty_version_is_an_error_instead_of_silent_history_fallback(self):
        result = self.generate("## [1.0.17]\n\n## [1.0.0]\nOld.\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("empty", result.stderr)
        self.assertNotIn("Fixture maintenance change", result.stdout)

    def test_comment_only_version_is_rejected_as_empty(self):
        result = self.generate("## [1.0.17]\n<!-- TODO: write notes\nbefore release -->\n\n<!-- placeholder -->\n## [1.0.0]\nOld.\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("empty", result.stderr)
        self.assertNotIn("# Downright", result.stdout)

    def test_duplicate_versions_are_rejected(self):
        result = self.generate("## [1.0.17]\nFirst.\n## [1.0.17]\nSecond.\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate", result.stderr)

    def test_unreadable_changelog_is_not_treated_as_an_unlisted_version(self):
        result = self.generate(None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release-notes:", result.stderr)
        self.assertNotIn("Fixture maintenance change", result.stdout)


if __name__ == "__main__":
    unittest.main()
