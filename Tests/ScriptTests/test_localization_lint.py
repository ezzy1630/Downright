"""Regression tests for localization sync checks and unwrapped UI literal lint."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import textwrap
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]


def _load_script(name: str, filename: str):
    path = REPO_ROOT / "Scripts" / filename
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


CHECK_L10N = _load_script("check_localization_test", "check-localization.py")
LINT_L10N = _load_script("lint_localization_test", "lint-localization.py")


class TestLocalizationSyncChecks(unittest.TestCase):
    def _make_mini_repo(self, root: Path, app_swift: str, zh_strings: str, ql_swift: str = "", ql_zh: str = ""):
        (root / "Sources/DownrightApp/Support").mkdir(parents=True)
        (root / "Sources/DownrightApp/Resources/en.lproj").mkdir(parents=True)
        (root / "Sources/DownrightApp/Resources/zh-Hans.lproj").mkdir(parents=True)
        (root / "Sources/DownrightQL/Resources/zh-Hans.lproj").mkdir(parents=True)

        (root / "Sources/DownrightApp/Support/Commands.swift").write_text(
            textwrap.dedent("""
                enum Command {
                    var title: String { L10n.tr(englishTitle) }
                    var englishTitle: String {
                        switch self {
                        case .open: return "Open…"
                        }
                    }
                }
            """),
            encoding="utf-8",
        )
        (root / "Sources/DownrightApp/Support/Sample.swift").write_text(
            textwrap.dedent(app_swift), encoding="utf-8"
        )
        (root / "Sources/DownrightApp/Resources/zh-Hans.lproj/Localizable.strings").write_text(
            textwrap.dedent(zh_strings), encoding="utf-8"
        )
        info = '"NSHumanReadableCopyright" = "MIT";\n'
        (root / "Sources/DownrightApp/Resources/en.lproj/InfoPlist.strings").write_text(info, encoding="utf-8")
        (root / "Sources/DownrightApp/Resources/zh-Hans.lproj/InfoPlist.strings").write_text(info, encoding="utf-8")

        (root / "Sources/DownrightQL/Preview.swift").write_text(textwrap.dedent(ql_swift), encoding="utf-8")
        (root / "Sources/DownrightQL/Resources/zh-Hans.lproj/Localizable.strings").write_text(
            textwrap.dedent(ql_zh), encoding="utf-8"
        )

    def test_positional_specifiers_reordered_pass_and_wrong_types_fail(self):
        en_specs, err1 = CHECK_L10N.parse_format_specifiers("%@ of %lld items")
        zh_reordered, err2 = CHECK_L10N.parse_format_specifiers("共 %2$lld 项中的 %1$@")
        zh_swapped_types, err3 = CHECK_L10N.parse_format_specifiers("共 %1$lld 项中的 %2$@")
        self.assertIsNone(err1)
        self.assertIsNone(err2)
        self.assertIsNone(err3)
        self.assertEqual(en_specs, zh_reordered)
        self.assertNotEqual(en_specs, zh_swapped_types)

        _, mixed_err = CHECK_L10N.parse_format_specifiers("%1$@ and %lld")
        self.assertIsNotNone(mixed_err)

    def test_missing_context_key_unused_key_and_duplicate_en_table_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._make_mini_repo(
                root,
                app_swift="""
                    let a = L10n.tr("System", context: "theme")
                    let b = L10n.tr("Step %lld of %lld", 1, 3)
                """,
                zh_strings="""
                    "Open…" = "打开…";
                    "Step %lld of %lld" = "共 %2$lld 步，第 %1$lld 步";
                    "Orphaned key" = "废弃键";
                """,
                ql_swift='let q = QLL10n.tr("Preview")',
                ql_zh='"Preview" = "预览";',
            )
            (root / "Sources/DownrightApp/Resources/en.lproj/Localizable.strings").write_text(
                '"Open…" = "Open…";\n', encoding="utf-8"
            )
            errors = CHECK_L10N.check_repo(root)
            joined = "\n".join(errors)
            self.assertIn("remove duplicate English Localizable.strings", joined)
            self.assertIn("missing zh-Hans translation for 'theme::System'", joined)
            self.assertIn("unused zh-Hans key 'Orphaned key'", joined)

    def test_clean_repo_passes_including_positional_specifiers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._make_mini_repo(
                root,
                app_swift="""
                    let a = L10n.tr("System", context: "theme")
                    let b = L10n.tr("%@ has %lld items", "Folder", 5)
                """,
                zh_strings="""
                    "Open…" = "打开…";
                    "theme::System" = "跟随系统";
                    "%@ has %lld items" = "共有 %2$lld 项（%1$@）";
                """,
                ql_swift='let q = QLL10n.tr("Preview")',
                ql_zh='"Preview" = "预览";',
            )
            errors = CHECK_L10N.check_repo(root)
            self.assertEqual(errors, [])


class TestLocalizationUILiteralLint(unittest.TestCase):
    def test_catches_unwrapped_ui_sinks_and_enforces_allowlist(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "Sources/DownrightApp/Panels"
            target.mkdir(parents=True)
            (target / "DemoView.swift").write_text(
                textwrap.dedent("""
                    import AppKit
                    func build() {
                        label.stringValue = "Hardcoded label"
                        window.title = "Downright"
                        field.placeholderString = "Search here"
                        alert.messageText = "Something failed"
                        alert.informativeText = "Details here"
                        button.toolTip = "Click me"
                        button.setAccessibilityLabel("Close panel")
                        alert.addButton(withTitle: "Proceed")
                        _ = PanelButton.text("Save Now", action: action)
                        _ = NSTextField(labelWithString: "Hello world")
                        _ = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
                        _ = NSImage(systemSymbolName: "star", accessibilityDescription: "Star item")
                        // Wrapped strings must pass cleanly
                        label.stringValue = L10n.tr("Wrapped")
                        label.stringValue = "—"
                    }
                """),
                encoding="utf-8",
            )
            allowlist = root / "Scripts/l10n-lint-allowlist.json"
            allowlist.parent.mkdir(parents=True)
            allowlist.write_text(
                json.dumps(
                    [
                        {
                            "path": "Sources/DownrightApp/Panels/DemoView.swift",
                            "literal": "Downright",
                            "reason": "Product brand name.",
                        },
                        {
                            "path": "Sources/DownrightApp/Panels/DemoView.swift",
                            "literal": "Stale literal",
                            "reason": "Should fail as stale.",
                        },
                    ]
                ),
                encoding="utf-8",
            )

            errors, unallowed = LINT_L10N.lint_repo(root, allowlist_path=allowlist)
            literals = {f.literal for f in unallowed}
            self.assertEqual(
                literals,
                {
                    "Hardcoded label",
                    "Search here",
                    "Something failed",
                    "Details here",
                    "Click me",
                    "Close panel",
                    "Proceed",
                    "Save Now",
                    "Hello world",
                    "Export",
                    "Star item",
                },
            )
            joined = "\n".join(errors)
            self.assertIn("Fix: wrap in L10n.tr(", joined)
            self.assertIn("stale allowlist entry", joined)


if __name__ == "__main__":
    unittest.main()
