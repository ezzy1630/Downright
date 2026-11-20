#!/usr/bin/env python3
"""Verify localization table integrity and source-to-strings sync.

Checks:
1. No duplicate English Localizable.strings tables exist (English keys are the
   source of truth and fallback).
2. InfoPlist.strings keys stay in sync between en.lproj and zh-Hans.lproj.
3. Every L10n.tr / QLL10n.tr call in Sources/ (including context:: keys and
   Command.englishTitle) has a non-empty zh-Hans entry, and zh-Hans has no
   unused or duplicate keys.
4. Format specifiers match between English keys and zh-Hans translations,
   accepting positional reordering (%1$@, %2$lld, etc.), and call sites pass
   the expected argument count.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
import sys


REPO_ROOT = Path(__file__).resolve().parent.parent

# Printf-style format specifiers recognised by Foundation String(format:).
FORMAT_SPEC_RE = re.compile(
    r"%(?:(?P<pos>\d+)\$)?(?P<flags>[-+ #0]*)(?P<width>\d+|\*)?"
    r"(?:\.(?P<prec>\d+|\*))?(?P<len>hh|h|ll|l|j|z|t|L)?"
    r"(?P<conv>[@dDiuUxXoOfeEgGcCsSp%])"
)

# Token kinds produced by the lightweight Swift lexer below.
# ('ident', value, line), ('string', decoded_value, has_interpolation, line),
# ('punct', char, line)
SWIFT_IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
UNICODE_ESCAPE_RE = re.compile(r"\\u\{([0-9A-Fa-f]+)\}")
STRINGS_UNICODE_RE = re.compile(r"\\U([0-9A-Fa-f]{4})")


@dataclass(frozen=True)
class TrCall:
    key: str
    english_text: str
    path: Path
    line: int
    arg_count: int


def decode_swift_string(raw: str, hashes: int) -> tuple[str, bool]:
    """Decode Swift string literal content and flag string interpolation."""
    prefix = "\\" + ("#" * hashes)
    out: list[str] = []
    has_interpolation = False
    i = 0
    n = len(raw)
    while i < n:
        if raw.startswith(prefix, i):
            j = i + len(prefix)
            if j >= n:
                out.append(raw[i:])
                break
            ch = raw[j]
            if ch == "(":
                has_interpolation = True
                out.append(raw[i : j + 1])
                i = j + 1
            elif ch == "n":
                out.append("\n")
                i = j + 1
            elif ch == "r":
                out.append("\r")
                i = j + 1
            elif ch == "t":
                out.append("\t")
                i = j + 1
            elif ch == "0":
                out.append("\0")
                i = j + 1
            elif ch == "\\":
                out.append("\\")
                i = j + 1
            elif ch == '"':
                out.append('"')
                i = j + 1
            elif ch == "'":
                out.append("'")
                i = j + 1
            elif ch == "u" and j + 1 < n and raw[j + 1] == "{":
                end = raw.find("}", j + 2)
                if end != -1:
                    out.append(chr(int(raw[j + 2 : end], 16)))
                    i = end + 1
                else:
                    out.append(ch)
                    i = j + 1
            elif ch == "\n":
                # Escaped newline in multiline string literal
                i = j + 1
            else:
                out.append(ch)
                i = j + 1
        else:
            out.append(raw[i])
            i += 1
    return "".join(out), has_interpolation


def strip_multiline_indent(raw: str) -> str:
    """Apply Swift's multiline string indentation stripping."""
    if raw.startswith("\n"):
        raw = raw[1:]
    lines = raw.split("\n")
    if not lines:
        return ""
    closing_indent = lines[-1]
    body_lines = lines[:-1]
    stripped = []
    for line in body_lines:
        if line.startswith(closing_indent):
            stripped.append(line[len(closing_indent) :])
        else:
            stripped.append(line)
    return "\n".join(stripped)


def strip_interpolations(raw: str, hashes: int) -> str:
    """Remove \\#*(...) interpolation expressions from raw Swift string content."""
    prefix = "\\" + ("#" * hashes) + "("
    out: list[str] = []
    i = 0
    n = len(raw)
    while i < n:
        if raw.startswith(prefix, i):
            i += len(prefix)
            depth = 1
            while i < n and depth > 0:
                ch = raw[i]
                if ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                elif ch == '"':
                    i += 1
                    while i < n and raw[i] != '"':
                        if raw[i] == "\\":
                            i += 2
                        else:
                            i += 1
                i += 1
            continue
        out.append(raw[i])
        i += 1
    return "".join(out)


def extract_interpolation_sources(raw: str, hashes: int, start_line: int) -> list[tuple[str, int]]:
    """Return `(expr_source, line_number)` for every \\#*(...) interpolation in `raw`."""
    prefix = "\\" + ("#" * hashes) + "("
    exprs: list[tuple[str, int]] = []
    i = 0
    n = len(raw)
    line = start_line
    while i < n:
        if raw.startswith(prefix, i):
            i += len(prefix)
            expr_start = i
            expr_line = line
            depth = 1
            while i < n and depth > 0:
                ch = raw[i]
                if ch == "\n":
                    line += 1
                elif ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                    if depth == 0:
                        exprs.append((raw[expr_start:i], expr_line))
                        i += 1
                        break
                elif ch == '"':
                    i += 1
                    while i < n and raw[i] != '"':
                        if raw[i] == "\n":
                            line += 1
                        if raw[i] == "\\":
                            i += 2
                        else:
                            i += 1
                i += 1
            continue
        if raw[i] == "\n":
            line += 1
        i += 1
    return exprs


def tokenize_swift(source: str, base_line: int = 1, expand_interpolations: bool = False) -> list[tuple]:
    """Tokenize Swift source, skipping comments and decoding string literals.

    String tokens are 5-tuples:
      ('string', decoded_value, has_interpolation, line, static_text_without_interpolations)
    """
    tokens: list[tuple] = []
    i = 0
    n = len(source)
    line = base_line
    while i < n:
        ch = source[i]
        if ch == "\n":
            line += 1
            i += 1
            continue
        if ch in " \t\r":
            i += 1
            continue
        # Line comment
        if ch == "/" and i + 1 < n and source[i + 1] == "/":
            nl = source.find("\n", i + 2)
            if nl == -1:
                break
            i = nl
            continue
        # Nested block comment
        if ch == "/" and i + 1 < n and source[i + 1] == "*":
            depth = 1
            i += 2
            while i < n and depth > 0:
                if source[i] == "\n":
                    line += 1
                    i += 1
                elif source[i : i + 2] == "/*":
                    depth += 1
                    i += 2
                elif source[i : i + 2] == "*/":
                    depth -= 1
                    i += 2
                else:
                    i += 1
            continue
        # Raw or normal string literal: #*"..."#* or #*"""..."""#*
        if ch == "#" or ch == '"':
            start_i = i
            start_line = line
            hashes = 0
            while i < n and source[i] == "#":
                hashes += 1
                i += 1
            if i < n and source[i] == '"':
                if source[i : i + 3] == '"""':
                    quote = '"""'
                    i += 3
                else:
                    quote = '"'
                    i += 1
                content_start = i
                esc_prefix = "\\" + ("#" * hashes)
                end_marker = quote + ("#" * hashes)
                interp_depth = 0
                while i < n:
                    if source[i] == "\n":
                        line += 1
                    if interp_depth == 0 and source.startswith(end_marker, i):
                        raw = source[content_start:i]
                        i += len(end_marker)
                        if quote == '"""':
                            raw = strip_multiline_indent(raw)
                        decoded, has_interp = decode_swift_string(raw, hashes)
                        static_part = decoded
                        if has_interp:
                            static_part, _ = decode_swift_string(strip_interpolations(raw, hashes), hashes)
                        tokens.append(("string", decoded, has_interp, start_line, static_part))
                        if expand_interpolations and has_interp:
                            for expr_src, expr_line in extract_interpolation_sources(raw, hashes, start_line):
                                tokens.extend(tokenize_swift(expr_src, base_line=expr_line, expand_interpolations=True))
                        break
                    if interp_depth == 0 and source.startswith(esc_prefix, i):
                        after = i + len(esc_prefix)
                        if after < n and source[after] == "(":
                            interp_depth = 1
                            i = after + 1
                            continue
                        i = after + 1
                        continue
                    if interp_depth > 0:
                        if source[i] == "(":
                            interp_depth += 1
                        elif source[i] == ")":
                            interp_depth -= 1
                        elif source[i] == '"':
                            # Skip nested string inside interpolation
                            i += 1
                            while i < n and source[i] != '"':
                                if source[i] == "\\":
                                    i += 2
                                else:
                                    if source[i] == "\n":
                                        line += 1
                                    i += 1
                    i += 1
                continue
            # Not a string (e.g. #selector, #if, #expect)
            i = start_i
            tokens.append(("punct", "#", line))
            i += 1
            continue
        # Identifier
        m = SWIFT_IDENT_RE.match(source, i)
        if m:
            tokens.append(("ident", m.group(0), line))
            i = m.end()
            continue
        # Punctuation / operators
        tokens.append(("punct", ch, line))
        i += 1
    return tokens


def split_call_arguments(tokens: list[tuple], open_paren: int) -> tuple[list[list[tuple]], int]:
    """Split a parenthesised Swift call argument list into top-level args."""
    args: list[list[tuple]] = []
    current: list[tuple] = []
    depth = 1
    i = open_paren + 1
    n = len(tokens)
    while i < n and depth > 0:
        tok = tokens[i]
        if tok[0] == "punct" and tok[1] in "([{":
            depth += 1
            current.append(tok)
        elif tok[0] == "punct" and tok[1] in ")]}":
            depth -= 1
            if depth == 0:
                if current:
                    args.append(current)
                return args, i
            current.append(tok)
        elif tok[0] == "punct" and tok[1] == "," and depth == 1:
            args.append(current)
            current = []
        else:
            current.append(tok)
        i += 1
    return args, n - 1


def extract_tr_calls(
    paths: list[Path],
    helper_name: str,
    allow_dynamic_at: set[tuple[str, str]] | None = None,
) -> tuple[list[TrCall], list[str]]:
    """Extract all `<helper_name>.tr(...)` calls from Swift files."""
    calls: list[TrCall] = []
    errors: list[str] = []
    allow_dynamic_at = allow_dynamic_at or set()

    for path in paths:
        rel = path.relative_to(REPO_ROOT).as_posix()
        source = path.read_text(encoding="utf-8")
        tokens = tokenize_swift(source, expand_interpolations=True)
        n = len(tokens)
        i = 0
        while i < n:
            if (
                tokens[i][0] == "ident"
                and tokens[i][1] == "tr"
                and i + 1 < n
                and tokens[i + 1][0] == "punct"
                and tokens[i + 1][1] == "("
            ):
                # Skip declarations like `static func tr(`
                if i >= 1 and tokens[i - 1][0] == "ident" and tokens[i - 1][1] == "func":
                    i += 1
                    continue
                is_qualified = (
                    i >= 2
                    and tokens[i - 1][0] == "punct"
                    and tokens[i - 1][1] == "."
                    and tokens[i - 2][0] == "ident"
                    and tokens[i - 2][1] == helper_name
                )
                # Bare `tr(...)` inside the helper's own file (e.g. L10n.swift)
                is_bare_in_helper = (
                    path.stem == helper_name
                    and (i == 0 or not (tokens[i - 1][0] == "punct" and tokens[i - 1][1] == "."))
                )
                if not (is_qualified or is_bare_in_helper):
                    i += 1
                    continue

                call_line = tokens[i][2]
                args, _ = split_call_arguments(tokens, i + 1)
                if not args:
                    errors.append(f"{rel}:{call_line}: empty {helper_name}.tr() call")
                    i += 2
                    continue

                first = args[0]
                if len(first) == 1 and first[0][0] == "string":
                    text, has_interp = first[0][1], first[0][2]
                    if has_interp:
                        errors.append(
                            f"{rel}:{call_line}: {helper_name}.tr() must not use string interpolation; "
                            f"use format specifiers (%@ / %lld) instead."
                        )
                        i += 2
                        continue
                    context: str | None = None
                    variadic_count = 0
                    for extra in args[1:]:
                        if (
                            len(extra) == 3
                            and extra[0][0] == "ident"
                            and extra[0][1] == "context"
                            and extra[1][0] == "punct"
                            and extra[1][1] == ":"
                            and extra[2][0] == "string"
                        ):
                            if extra[2][2]:
                                errors.append(
                                    f"{rel}:{call_line}: {helper_name}.tr() context must be a static literal"
                                )
                            context = extra[2][1]
                        else:
                            variadic_count += 1
                    key = f"{context}::{text}" if context else text
                    calls.append(TrCall(key=key, english_text=text, path=path, line=call_line, arg_count=variadic_count))
                else:
                    expr = "".join(t[1] for t in first)
                    if (rel, expr) not in allow_dynamic_at:
                        errors.append(
                            f"{rel}:{call_line}: non-literal argument `{expr}` passed to {helper_name}.tr(). "
                            f"Use a static string literal so missing translations are caught automatically."
                        )
                # Advance past `tr(` rather than `end_idx` so nested `L10n.tr(...)`
                # calls inside format arguments are also discovered.
                i += 2
                continue
            i += 1
    return calls, errors


def extract_command_english_titles(commands_path: Path) -> tuple[list[TrCall], list[str]]:
    """Extract all static English titles from `Command.englishTitle` in Commands.swift."""
    source = commands_path.read_text(encoding="utf-8")
    tokens = tokenize_swift(source)
    calls: list[TrCall] = []
    errors: list[str] = []

    # Locate `var englishTitle: String {`
    start = None
    for idx in range(len(tokens) - 4):
        if (
            tokens[idx][0] == "ident"
            and tokens[idx][1] == "var"
            and tokens[idx + 1][0] == "ident"
            and tokens[idx + 1][1] == "englishTitle"
        ):
            for j in range(idx + 2, len(tokens)):
                if tokens[j][0] == "punct" and tokens[j][1] == "{":
                    start = j
                    break
            break

    if start is None:
        return [], [f"{commands_path.relative_to(REPO_ROOT)}: could not find `var englishTitle`"]

    depth = 1
    i = start + 1
    while i < len(tokens) and depth > 0:
        if tokens[i][0] == "punct" and tokens[i][1] == "{":
            depth += 1
        elif tokens[i][0] == "punct" and tokens[i][1] == "}":
            depth -= 1
            if depth == 0:
                break
        elif (
            tokens[i][0] == "ident"
            and tokens[i][1] == "return"
            and i + 1 < len(tokens)
            and tokens[i + 1][0] == "string"
        ):
            text, has_interp, line = tokens[i + 1][1], tokens[i + 1][2], tokens[i + 1][3]
            if has_interp:
                errors.append(f"{commands_path.relative_to(REPO_ROOT)}:{line}: interpolated Command.englishTitle")
            else:
                calls.append(TrCall(key=text, english_text=text, path=commands_path, line=line, arg_count=0))
        i += 1

    if not calls:
        errors.append(f"{commands_path.relative_to(REPO_ROOT)}: extracted zero titles from Command.englishTitle")
    return calls, errors


def decode_strings_value(raw: str) -> str:
    """Decode an Apple .strings quoted string."""
    out: list[str] = []
    i = 0
    n = len(raw)
    while i < n:
        if raw[i] == "\\" and i + 1 < n:
            nxt = raw[i + 1]
            if nxt == "n":
                out.append("\n")
                i += 2
            elif nxt == "r":
                out.append("\r")
                i += 2
            elif nxt == "t":
                out.append("\t")
                i += 2
            elif nxt == '"':
                out.append('"')
                i += 2
            elif nxt == "\\":
                out.append("\\")
                i += 2
            elif nxt in ("U", "u") and i + 6 <= n and re.fullmatch(r"[0-9A-Fa-f]{4}", raw[i + 2 : i + 6]):
                out.append(chr(int(raw[i + 2 : i + 6], 16)))
                i += 6
            else:
                out.append(nxt)
                i += 2
        else:
            out.append(raw[i])
            i += 1
    return "".join(out)


def parse_strings_file(path: Path) -> tuple[dict[str, tuple[str, int]], list[str]]:
    """Parse an Apple .strings file, reporting syntax errors and duplicate keys."""
    text = path.read_text(encoding="utf-8")
    entries: dict[str, tuple[str, int]] = {}
    errors: list[str] = []
    rel = path.relative_to(REPO_ROOT).as_posix() if path.is_relative_to(REPO_ROOT) else str(path)

    i = 0
    n = len(text)
    line = 1

    def skip_ws_and_comments() -> None:
        nonlocal i, line
        while i < n:
            if text[i] == "\n":
                line += 1
                i += 1
            elif text[i] in " \t\r\ufeff":
                i += 1
            elif text[i : i + 2] == "//":
                nl = text.find("\n", i + 2)
                if nl == -1:
                    i = n
                else:
                    i = nl
            elif text[i : i + 2] == "/*":
                end = text.find("*/", i + 2)
                if end == -1:
                    errors.append(f"{rel}:{line}: unterminated block comment")
                    i = n
                else:
                    line += text[i : end + 2].count("\n")
                    i = end + 2
            else:
                break

    def read_quoted() -> tuple[str | None, int]:
        nonlocal i, line
        start_line = line
        if i >= n or text[i] != '"':
            return None, start_line
        i += 1
        buf: list[str] = []
        while i < n:
            ch = text[i]
            if ch == "\n":
                line += 1
            if ch == "\\" and i + 1 < n:
                buf.append(ch)
                buf.append(text[i + 1])
                if text[i + 1] == "\n":
                    line += 1
                i += 2
                continue
            if ch == '"':
                i += 1
                return decode_strings_value("".join(buf)), start_line
            buf.append(ch)
            i += 1
        errors.append(f"{rel}:{start_line}: unterminated string literal")
        return None, start_line

    while True:
        skip_ws_and_comments()
        if i >= n:
            break
        key, key_line = read_quoted()
        if key is None:
            errors.append(f"{rel}:{key_line}: expected quoted key")
            break
        skip_ws_and_comments()
        if i >= n or text[i] != "=":
            errors.append(f"{rel}:{line}: expected '=' after key {key!r}")
            break
        i += 1
        skip_ws_and_comments()
        val, val_line = read_quoted()
        if val is None:
            errors.append(f"{rel}:{val_line}: expected quoted value for key {key!r}")
            break
        skip_ws_and_comments()
        if i >= n or text[i] != ";":
            errors.append(f"{rel}:{line}: expected ';' after value for key {key!r}")
            break
        i += 1
        if key in entries:
            errors.append(f"{rel}:{key_line}: duplicate key {key!r} (first seen on line {entries[key][1]})")
        else:
            entries[key] = (val, key_line)

    return entries, errors


def parse_format_specifiers(text: str) -> tuple[dict[int, str], str | None]:
    """Parse printf format specifiers into {1-based position: canonical_type}.

    Supports positional specifiers (%1$@, %2$lld) so translations may reorder
    arguments without tripping parity checks. Rejects mixing positional and
    sequential specifiers in the same string.
    """
    specs: dict[int, str] = {}
    saw_positional = False
    saw_sequential = False
    seq = 0
    for m in FORMAT_SPEC_RE.finditer(text):
        conv = m.group("conv")
        if conv == "%":
            continue
        length = m.group("len") or ""
        # Normalize equivalent conversion letters while preserving width
        if conv in ("d", "i", "D"):
            canonical = f"{length}d"
        elif conv in ("u", "U", "x", "X", "o", "O"):
            canonical = f"{length}u"
        elif conv in ("f", "e", "E", "g", "G"):
            canonical = f"{length}f"
        else:
            canonical = f"{length}{conv}"

        pos_str = m.group("pos")
        if pos_str is not None:
            saw_positional = True
            pos = int(pos_str)
            if pos <= 0:
                return {}, f"invalid positional specifier %{pos_str}$"
        else:
            saw_sequential = True
            seq += 1
            pos = seq

        if pos in specs and specs[pos] != canonical:
            return {}, f"conflicting types for position {pos}: {specs[pos]} vs {canonical}"
        specs[pos] = canonical

    if saw_positional and saw_sequential:
        return {}, "mixes positional (%1$@) and sequential (%@) format specifiers"
    return specs, None


def verify_target(
    name: str,
    source_dir: Path,
    helper_name: str,
    zh_strings_path: Path,
    forbidden_en_strings: Path,
    extra_calls: list[TrCall] | None = None,
    allow_dynamic_at: set[tuple[str, str]] | None = None,
) -> list[str]:
    errors: list[str] = []

    if forbidden_en_strings.exists():
        rel = forbidden_en_strings.relative_to(REPO_ROOT).as_posix()
        errors.append(
            f"{rel}: remove duplicate English Localizable.strings — English keys in source "
            f"are already the canonical fallback."
        )

    if not zh_strings_path.exists():
        return errors + [f"Missing localization table: {zh_strings_path}"]

    swift_files = sorted(source_dir.rglob("*.swift"))
    calls, extract_errors = extract_tr_calls(swift_files, helper_name, allow_dynamic_at=allow_dynamic_at)
    errors.extend(extract_errors)
    if extra_calls:
        calls.extend(extra_calls)

    zh_entries, parse_errors = parse_strings_file(zh_strings_path)
    errors.extend(parse_errors)

    source_keys: dict[str, list[TrCall]] = {}
    for call in calls:
        source_keys.setdefault(call.key, []).append(call)

    zh_rel = zh_strings_path.relative_to(REPO_ROOT).as_posix()

    # 1. Missing zh-Hans translations
    for key in sorted(source_keys.keys()):
        first_call = source_keys[key][0]
        if key not in zh_entries:
            call_rel = first_call.path.relative_to(REPO_ROOT).as_posix()
            errors.append(
                f"{call_rel}:{first_call.line}: missing zh-Hans translation for {key!r}. "
                f"Add it to {zh_rel}."
            )
            continue
        zh_val, zh_line = zh_entries[key]
        if not zh_val.strip():
            errors.append(f"{zh_rel}:{zh_line}: empty zh-Hans translation for {key!r}")

        en_specs, en_err = parse_format_specifiers(first_call.english_text)
        zh_specs, zh_err = parse_format_specifiers(zh_val)
        if en_err:
            call_rel = first_call.path.relative_to(REPO_ROOT).as_posix()
            errors.append(f"{call_rel}:{first_call.line}: invalid format string {key!r}: {en_err}")
        elif zh_err:
            errors.append(f"{zh_rel}:{zh_line}: invalid format string for {key!r}: {zh_err}")
        elif en_specs != zh_specs:
            errors.append(
                f"{zh_rel}:{zh_line}: format specifier mismatch for {key!r}: "
                f"en={en_specs} zh-Hans={zh_specs}"
            )

        # Verify argument count at each call site when specifiers are present
        expected_args = max(en_specs.keys(), default=0)
        for call in source_keys[key]:
            if call.arg_count != expected_args:
                call_rel = call.path.relative_to(REPO_ROOT).as_posix()
                errors.append(
                    f"{call_rel}:{call.line}: {helper_name}.tr({call.english_text!r}) expects "
                    f"{expected_args} format argument(s), got {call.arg_count}"
                )

    # 2. Unused zh-Hans keys
    for key in sorted(zh_entries.keys()):
        if key not in source_keys:
            _, zh_line = zh_entries[key]
            errors.append(
                f"{zh_rel}:{zh_line}: unused zh-Hans key {key!r} (not referenced in {name} sources). "
                f"Remove it from {zh_rel}."
            )

    return errors


def verify_info_plist_strings(en_path: Path, zh_path: Path) -> list[str]:
    errors: list[str] = []
    for path in (en_path, zh_path):
        if not path.exists():
            errors.append(f"Missing InfoPlist.strings: {path}")
    if errors:
        return errors
    en_entries, en_errs = parse_strings_file(en_path)
    zh_entries, zh_errs = parse_strings_file(zh_path)
    errors.extend(en_errs)
    errors.extend(zh_errs)
    en_keys = set(en_entries.keys())
    zh_keys = set(zh_entries.keys())
    for missing in sorted(en_keys - zh_keys):
        errors.append(f"{zh_path.relative_to(REPO_ROOT)}: missing InfoPlist key {missing!r}")
    for extra in sorted(zh_keys - en_keys):
        errors.append(f"{zh_path.relative_to(REPO_ROOT)}: extra InfoPlist key {extra!r}")
    for key, (val, line) in zh_entries.items():
        if not val.strip():
            errors.append(f"{zh_path.relative_to(REPO_ROOT)}:{line}: empty InfoPlist value for {key!r}")
    return errors


def check_repo(root: Path = REPO_ROOT) -> list[str]:
    global REPO_ROOT
    prev_root = REPO_ROOT
    REPO_ROOT = root
    try:
        errors: list[str] = []

        commands_path = root / "Sources/DownrightApp/Support/Commands.swift"
        command_calls, cmd_errs = extract_command_english_titles(commands_path)
        errors.extend(cmd_errs)

        errors.extend(
            verify_target(
                name="DownrightApp",
                source_dir=root / "Sources/DownrightApp",
                helper_name="L10n",
                zh_strings_path=root / "Sources/DownrightApp/Resources/zh-Hans.lproj/Localizable.strings",
                forbidden_en_strings=root / "Sources/DownrightApp/Resources/en.lproj/Localizable.strings",
                extra_calls=command_calls,
                allow_dynamic_at={
                    ("Sources/DownrightApp/Support/Commands.swift", "englishTitle"),
                    ("Sources/DownrightApp/Support/L10n.swift", "format"),
                },
            )
        )
        errors.extend(
            verify_target(
                name="DownrightQL",
                source_dir=root / "Sources/DownrightQL",
                helper_name="QLL10n",
                zh_strings_path=root / "Sources/DownrightQL/Resources/zh-Hans.lproj/Localizable.strings",
                forbidden_en_strings=root / "Sources/DownrightQL/Resources/en.lproj/Localizable.strings",
                allow_dynamic_at={
                    ("Sources/DownrightQL/QLL10n.swift", "format"),
                },
            )
        )
        errors.extend(
            verify_info_plist_strings(
                root / "Sources/DownrightApp/Resources/en.lproj/InfoPlist.strings",
                root / "Sources/DownrightApp/Resources/zh-Hans.lproj/InfoPlist.strings",
            )
        )
        return errors
    finally:
        REPO_ROOT = prev_root


def main(argv: list[str] | None = None) -> int:
    root = Path(argv[1]).resolve() if argv and len(argv) > 1 else REPO_ROOT
    errors = check_repo(root)
    if errors:
        for err in errors:
            print(f"ERROR: {err}", file=sys.stderr)
        print(f"\nLocalization check failed with {len(errors)} issue(s).", file=sys.stderr)
        return 1
    print("Localization check passed (App + Quick Look + InfoPlist strings in sync).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
