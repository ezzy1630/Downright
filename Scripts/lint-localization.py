#!/usr/bin/env python3
"""Lint user-visible UI text sinks for unwrapped string literals.

Checks Sources/DownrightApp and Sources/DownrightQL for string literals passed
directly to AppKit and panel UI text properties/initializers without going
through L10n.tr / QLL10n.tr, with an explicit allowlist in
Scripts/l10n-lint-allowlist.json.
"""
from __future__ import annotations

from dataclasses import dataclass
import importlib.util
import json
from pathlib import Path
import re
import sys


REPO_ROOT = Path(__file__).resolve().parent.parent


def _load_check_localization():
    mod_path = Path(__file__).resolve().parent / "check-localization.py"
    spec = importlib.util.spec_from_file_location("check_localization", mod_path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["check_localization"] = module
    spec.loader.exec_module(module)
    return module


_MOD = _load_check_localization()
tokenize_swift = _MOD.tokenize_swift
split_call_arguments = _MOD.split_call_arguments

# Strings with at least one letter (Latin or CJK) are candidate user-visible copy.
# Pure punctuation/symbols/digits/whitespace ("—", "×", "·", "0", "") are skipped.
HAS_LETTER_RE = re.compile(r"[A-Za-z\u4E00-\u9FFF]")

# Property assignments on UI views/controls/alerts/panels whose RHS is visible text.
UI_ASSIGNMENT_PROPERTIES = {
    "stringValue",
    "title",
    "alternateTitle",
    "placeholderString",
    "messageText",
    "informativeText",
    "toolTip",
    "prompt",
    "message",
    "paletteLabel",
    "metricsSummary",
}

# Call patterns: (callee_chain, set_of_arg_specs)
# arg_spec is either an int (0-based positional argument) or a str (argument label).
UI_CALL_SINKS: list[tuple[tuple[str, ...], set[int | str]]] = [
    (("setAccessibilityLabel",), {0}),
    (("setAccessibilityTitle",), {0}),
    (("setAccessibilityHelp",), {0}),
    (("setAccessibilityValue",), {0}),
    (("addButton",), {"withTitle"}),
    (("PanelButton", "text"), {0}),
    (("PanelButton", "symbol"), {"label"}),
    (("PanelButton", "toggle"), {0, "label"}),
    (("PanelSegmentedControl",), {"items"}),
    (("PanelBadge",), {"text"}),
    (("NSTextField",), {"labelWithString", "wrappingLabelWithString", "string"}),
    (("NSButton",), {"title", "checkboxWithTitle", "radioButtonWithTitle"}),
    (("NSMenu",), {"title"}),
    (("NSMenuItem",), {"title"}),
    (("addItem",), {"withTitle"}),
    (("insertItem",), {"withTitle"}),
    (("addItems",), {"withTitles"}),
    (("setLabel",), {0}),
    (("setToolTip",), {0}),
    (("NSSegmentedControl",), {"labels"}),
    (("NSImage",), {"accessibilityDescription"}),
    (("emptyState", "configure"), {"title", "subtitle"}),
    (("PreferenceRow", "section"), {0}),
    (("PreferenceRow", "toggle"), {0, "help"}),
    (("PreferenceRow", "stepper"), {0, "help"}),
    (("PreferenceRow", "choice"), {0, "help"}),
    (("PreferenceRow", "text"), {0, "help"}),
    (("PreferenceRow", "button"), {0}),
    (("PreferenceRow", "note"), {0}),
    # Implicit-member enum cases inside `[PreferenceRow]` arrays: `.section(...)`, etc.
    (("section",), {0}),
    (("toggle",), {0, "help"}),
    (("stepper",), {0, "help"}),
    (("choice",), {0, "help"}),
    (("button",), {0}),
    (("note",), {0}),
]

# Non-UI calls whose `.section(...)` / `.text(...)` / `.choice(...)` could collide
# if we weren't careful — only inspect implicit-member PreferenceRow cases inside
# PreferencesWindowController.swift.
PREF_ROW_ONLY_SINKS = {"section", "toggle", "stepper", "choice", "button", "note"}


@dataclass(frozen=True)
class Finding:
    rel_path: str
    line: int
    sink: str
    literal: str


def _is_l10n_wrapped(expr_tokens: list[tuple]) -> bool:
    """Return True if expr_tokens is a direct L10n.tr(...) / QLL10n.tr(...) call."""
    if not expr_tokens:
        return False
    for idx in range(len(expr_tokens) - 2):
        if (
            expr_tokens[idx][0] == "ident"
            and expr_tokens[idx][1] in ("L10n", "QLL10n")
            and expr_tokens[idx + 1][0] == "punct"
            and expr_tokens[idx + 1][1] == "."
        ):
            return True
    return False


def _extract_unwrapped_literals(expr_tokens: list[tuple]) -> list[tuple[str, int]]:
    """Find unwrapped string literals that contribute directly to an expression's value.

    Handles plain literals ("Foo"), string interpolations ("Foo \\(bar)"),
    array literals (["Foo", "Bar"]), and ternary branches (cond ? "A" : "B"),
    while ignoring string arguments nested inside L10n.tr(...) / QLL10n.tr(...)
    or helper calls like NSImage(systemSymbolName: "foo").
    """
    results: list[tuple[str, int]] = []
    n = len(expr_tokens)
    if n == 0:
        return results

    # Split on top-level `?` / `:` (ternary) or `,` inside `[...]` array literals
    # Walk token by token, skipping any parenthesized call arguments after an
    # identifier (e.g. L10n.tr("..."), NSImage(systemSymbolName: "..."), etc.).
    i = 0
    while i < n:
        tok = expr_tokens[i]
        # Skip `key: ...` labels inside non-array expressions? No, handled by caller.
        if tok[0] == "ident":
            # Check if this identifier (possibly dotted) starts a function/method call
            j = i
            while (
                j + 2 < n
                and expr_tokens[j + 1][0] == "punct"
                and expr_tokens[j + 1][1] == "."
                and expr_tokens[j + 2][0] == "ident"
            ):
                j += 2
            if j + 1 < n and expr_tokens[j + 1][0] == "punct" and expr_tokens[j + 1][1] == "(":
                _, end_idx = split_call_arguments(expr_tokens, j + 1)
                i = end_idx + 1
                continue
        if tok[0] == "punct" and tok[1] == ".":
            # Implicit member call like `.font(...)` or `.tr(...)`
            if i + 2 < n and expr_tokens[i + 1][0] == "ident" and expr_tokens[i + 2][0] == "punct" and expr_tokens[i + 2][1] == "(":
                _, end_idx = split_call_arguments(expr_tokens, i + 2)
                i = end_idx + 1
                continue
        if tok[0] == "punct" and tok[1] == "[":
            # Inspect elements of an array literal `[...]`
            depth = 1
            k = i + 1
            elem: list[tuple] = []
            while k < n and depth > 0:
                t = expr_tokens[k]
                if t[0] == "punct" and t[1] in "([{":
                    depth += 1
                    elem.append(t)
                elif t[0] == "punct" and t[1] in ")]}":
                    depth -= 1
                    if depth == 0:
                        results.extend(_extract_unwrapped_literals(elem))
                        break
                    elem.append(t)
                elif t[0] == "punct" and t[1] == "," and depth == 1:
                    results.extend(_extract_unwrapped_literals(elem))
                    elem = []
                else:
                    elem.append(t)
                k += 1
            i = k + 1
            continue
        if tok[0] == "string":
            # Skip condition strings in `foo == "bar" ? ... : ...`
            if i >= 1 and expr_tokens[i - 1][0] == "punct" and expr_tokens[i - 1][1] in ("=", "!"):
                i += 1
                continue
            if i + 1 < n and expr_tokens[i + 1][0] == "punct" and expr_tokens[i + 1][1] in ("=", "!"):
                i += 1
                continue
            val, has_interp, line, static_part = tok[1], tok[2], tok[3], tok[4]
            if HAS_LETTER_RE.search(static_part):
                results.append((val, line))
            elif has_interp:
                # Inspect expressions inside `\(...)` for unwrapped ternary literals
                # like `"\(flag ? "Completed" : "Incomplete")"` while ignoring
                # `\(L10n.tr("..."))`.
                for expr_src, expr_line in _MOD.extract_interpolation_sources(val, 0, line):
                    inner_tokens = tokenize_swift(expr_src, base_line=expr_line)
                    results.extend(_extract_unwrapped_literals(inner_tokens))
        i += 1
    return results


def _statement_end(tokens: list[tuple], start: int) -> int:
    """Find the end of a Swift assignment RHS starting at `start`."""
    n = len(tokens)
    if start >= n:
        return start
    start_line = tokens[start][2] if tokens[start][0] != "string" else tokens[start][3]
    depth = 0
    i = start
    while i < n:
        tok = tokens[i]
        tok_line = tok[2] if tok[0] != "string" else tok[3]
        if tok[0] == "punct" and tok[1] in "([{":
            depth += 1
        elif tok[0] == "punct" and tok[1] in ")]}":
            if depth == 0:
                return i
            depth -= 1
        elif depth == 0 and tok[0] == "punct" and tok[1] in (";", ","):
            return i
        elif depth == 0 and tok_line > start_line:
            # Allow continuation lines starting with ternary `?` / `:` / `+` / `??`
            if tok[0] == "punct" and tok[1] in ("?", ":", "+"):
                start_line = tok_line
            elif (
                i > start
                and tokens[i - 1][0] == "punct"
                and tokens[i - 1][1] in ("?", ":", "+", "=")
            ):
                start_line = tok_line
            else:
                return i
        i += 1
    return n


def scan_file(path: Path, root: Path) -> list[Finding]:
    rel = path.relative_to(root).as_posix()
    source = path.read_text(encoding="utf-8")
    tokens = tokenize_swift(source)
    findings: list[Finding] = []
    n = len(tokens)
    is_pref_file = path.name == "PreferencesWindowController.swift"

    # Build quick lookup from final callee name to sink specs
    sinks_by_last: dict[str, list[tuple[tuple[str, ...], set[int | str]]]] = {}
    for chain, arg_specs in UI_CALL_SINKS:
        sinks_by_last.setdefault(chain[-1], []).append((chain, arg_specs))

    i = 0
    while i < n:
        tok = tokens[i]

        # 1. Property assignments: `<prop> = <expr>`
        if (
            tok[0] == "ident"
            and tok[1] in UI_ASSIGNMENT_PROPERTIES
            and i + 1 < n
            and tokens[i + 1][0] == "punct"
            and tokens[i + 1][1] == "="
            and not (i + 2 < n and tokens[i + 2][0] == "punct" and tokens[i + 2][1] == "=")
        ):
            # Ignore Swift property declarations (`var title = ...`, `let title = ...`, default params `title: String = ...`)
            prev_is_decl = (
                i >= 1 and tokens[i - 1][0] == "ident" and tokens[i - 1][1] in ("var", "let", "case")
            )
            # Ignore `title =` inside struct/class property declarations with type annotation handled by `:` not `=`,
            # and ignore `guard let title =` or `if let title =`.
            if not prev_is_decl:
                # For short generic names like `title`, `prompt`, `message`, require either `obj.prop =`
                # or explicit known context so we don't flag unrelated local variables like `var prompt = ...`
                # (Wait: `title =` inside NSViewController/NSWindowController subclasses IS valid UI text!).
                rhs_start = i + 2
                rhs_end = _statement_end(tokens, rhs_start)
                rhs = tokens[rhs_start:rhs_end]
                for lit, line in _extract_unwrapped_literals(rhs):
                    findings.append(Finding(rel_path=rel, line=line, sink=f".{tok[1]} =", literal=lit))

        # 2. Method / initializer calls
        if (
            tok[0] == "ident"
            and tok[1] in sinks_by_last
            and i + 1 < n
            and tokens[i + 1][0] == "punct"
            and tokens[i + 1][1] == "("
        ):
            # Skip function declarations (`func setLabel(...)`)
            if i >= 1 and tokens[i - 1][0] == "ident" and tokens[i - 1][1] == "func":
                i += 1
                continue
            # Match longest chain backwards (e.g. `PanelButton.text` vs `text`)
            matched_chain: tuple[str, ...] | None = None
            matched_specs: set[int | str] | None = None
            for chain, specs in sorted(sinks_by_last[tok[1]], key=lambda pair: -len(pair[0])):
                if len(chain) == 1:
                    if chain[0] in PREF_ROW_ONLY_SINKS:
                        # Only implicit `.section(...)` etc. inside PreferencesWindowController
                        if not (is_pref_file and i >= 1 and tokens[i - 1][0] == "punct" and tokens[i - 1][1] == "."):
                            continue
                    matched_chain = chain
                    matched_specs = specs
                    break
                # Check preceding `<prefix>.<name>`
                ok = True
                pos = i
                for part in reversed(chain[:-1]):
                    if (
                        pos >= 2
                        and tokens[pos - 1][0] == "punct"
                        and tokens[pos - 1][1] == "."
                        and tokens[pos - 2][0] == "ident"
                        and tokens[pos - 2][1] == part
                    ):
                        pos -= 2
                    else:
                        ok = False
                        break
                if ok:
                    matched_chain = chain
                    matched_specs = specs
                    break

            if matched_chain and matched_specs:
                args, _ = split_call_arguments(tokens, i + 1)
                sink_name = ".".join(matched_chain) + "(...)"
                for idx, arg in enumerate(args):
                    label: str | None = None
                    value_tokens = arg
                    if (
                        len(arg) >= 2
                        and arg[0][0] == "ident"
                        and arg[1][0] == "punct"
                        and arg[1][1] == ":"
                    ):
                        label = arg[0][1]
                        value_tokens = arg[2:]
                    if (label is not None and label in matched_specs) or (label is None and idx in matched_specs):
                        for lit, line in _extract_unwrapped_literals(value_tokens):
                            label_suffix = f" ({label}:)" if label else ""
                            findings.append(
                                Finding(rel_path=rel, line=line, sink=f"{sink_name}{label_suffix}", literal=lit)
                            )
        i += 1

    return findings


def load_allowlist(path: Path) -> list[dict]:
    if not path.exists():
        return []
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        raise ValueError(f"{path}: expected a JSON array")
    return data


def lint_repo(root: Path = REPO_ROOT, allowlist_path: Path | None = None) -> tuple[list[str], list[Finding]]:
    allow_path = allowlist_path or (root / "Scripts/l10n-lint-allowlist.json")
    entries = load_allowlist(allow_path)
    allow_map: dict[tuple[str, str], dict] = {}
    errors: list[str] = []
    for entry in entries:
        key = (entry["path"], entry["literal"])
        if not entry.get("reason", "").strip():
            errors.append(f"Allowlist entry {key} is missing a non-empty `reason`.")
        allow_map[key] = entry

    matched_keys: set[tuple[str, str]] = set()
    unallowed: list[Finding] = []

    target_dirs = [
        root / "Sources/DownrightApp",
        root / "Sources/DownrightQL",
    ]
    for target_dir in target_dirs:
        if not target_dir.exists():
            continue
        for swift_file in sorted(target_dir.rglob("*.swift")):
            for finding in scan_file(swift_file, root):
                key = (finding.rel_path, finding.literal)
                if key in allow_map:
                    matched_keys.add(key)
                else:
                    unallowed.append(finding)

    for finding in unallowed:
        target = "DownrightQL" if finding.rel_path.startswith("Sources/DownrightQL/") else "DownrightApp"
        helper = "QLL10n.tr" if target == "DownrightQL" else "L10n.tr"
        errors.append(
            f"{finding.rel_path}:{finding.line}: unwrapped UI string literal in `{finding.sink}`: {finding.literal!r}\n"
            f"  Fix: wrap in {helper}({finding.literal!r}) and add a zh-Hans entry in "
            f"Sources/{target}/Resources/zh-Hans.lproj/Localizable.strings.\n"
            f"  If genuinely non-translatable (brand name, symbol, technical token), add an explained "
            f"entry to Scripts/l10n-lint-allowlist.json."
        )

    for key in sorted(set(allow_map.keys()) - matched_keys):
        errors.append(
            f"Scripts/l10n-lint-allowlist.json: stale allowlist entry for {key[0]} literal {key[1]!r} "
            f"(no longer matched — remove it)."
        )

    return errors, unallowed


def main(argv: list[str] | None = None) -> int:
    root = Path(argv[1]).resolve() if argv and len(argv) > 1 else REPO_ROOT
    errors, _ = lint_repo(root)
    if errors:
        for err in errors:
            print(f"ERROR: {err}", file=sys.stderr)
        print(f"\nLocalization UI literal lint failed with {len(errors)} issue(s).", file=sys.stderr)
        return 1
    print("Localization UI literal lint passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
