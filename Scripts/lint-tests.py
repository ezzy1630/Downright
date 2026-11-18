#!/usr/bin/env python3
"""Check a small set of test-honesty rules without language toolchains."""
import ast
from collections import Counter
import json
from pathlib import Path
import re
import sys


MESSAGES = {
    "fixed-wait": "Wait for a completion, notification, or an observable state with a deadline.",
    "time-limit": "Keep the suite's time limit. Await the operation's completion with a diagnostic deadline.",
    "assertion-retry": "Wait on the condition, then assert once. Keep independent cases as separate iterations.",
    "known-issue": "Give withKnownIssue a literal reason and a link to the tracked issue.",
    "test-double": "Exercise the real implementation. Observe calls with a recorder or use the real boundary.",
}

# Mask comments and literals without changing offsets. Keep literal spans so
# known-issue reasons can be inspected without treating fixture text as code.
SWIFT_NON_CODE = re.compile(r'//[^\n]*|/\*|(?P<raw>\#*)(?P<quote>"""|")')
SWIFT_WAIT = re.compile(
    r"\b(?:Thread|Task(?:\s*<[^;{}\n]+>)?|Darwin)\s*\.\s*(?:u?sleep)\s*\("
    r"|(?<![.\w])u?sleep\s*\("
    r"|\bRunLoop\s*\.\s*(?:current|main)\s*\.\s*run\s*\(\s*until\s*:"
    r"|\.\s*asyncAfter\s*\(\s*(?:deadline|wallDeadline)\s*:"
)
NESTED_COMMENT = re.compile(r"/\*|\*/")
ISSUE_URL = re.compile(r"https?://[^\s\"<>/]+/[^\s\"<>]+")
DOUBLE_NAME = r"(?:(?:Fake|Mock|Stub)[A-Z]\w*|\w+(?:Fake|Mock|Stub)|Fake|Mock|Stub)"
SWIFT_DOUBLE = re.compile(rf"\b(?:class|struct|actor)\s+{DOUBLE_NAME}\s*:\s*[^{{]*?{{")
ASSERTION = re.compile(r"\b(?:XCTAssert\w*|XCTFail)\s*\(|#(?:expect|require)\s*\(|\bIssue\.record\s*\(")


def swift_code(source):
    parts = []
    literals = []
    cursor = 0
    while match := SWIFT_NON_CODE.search(source, cursor):
        parts.append(source[cursor:match.start()])
        end = match.end()
        if match[0] == "/*":
            depth = 1
            for token in NESTED_COMMENT.finditer(source, end):
                depth += 1 if token[0] == "/*" else -1
                if depth == 0:
                    end = token.end()
                    break
            else:
                end = len(source)
        elif quote := match["quote"]:
            hashes = match["raw"]
            close = re.compile(r"\\" + hashes + r"[\s\S]|" + re.escape(quote + hashes))
            for token in close.finditer(source, end):
                if token[0] == quote + hashes:
                    literals.append((match.start(), token.end(), source[end:token.start()]))
                    end = token.end()
                    break
            else:
                end = len(source)
        parts.append(re.sub(r"[^\n]", " ", source[match.start():end]))
        cursor = end
    parts.append(source[cursor:])
    return "".join(parts), literals


def closing_brace(code, opening):
    depth = 1
    for match in re.finditer(r"[{}]", code[opening + 1:]):
        depth += 1 if match[0] == "{" else -1
        if depth == 0:
            return opening + 1 + match.start()
    return len(code)


def swift_violations(source):
    code, literals = swift_code(source)
    checks = [
        ("fixed-wait", SWIFT_WAIT),
        ("time-limit", re.compile(r"\.\s*timeLimit\s*\(")),
    ]
    for rule, pattern in checks:
        for match in pattern.finditer(code):
            if not re.search(r"\bfunc\s+$", code[max(0, match.start() - 32):match.start()]):
                yield source.count("\n", 0, match.start()) + 1, rule

    for match in re.finditer(r"\bwithKnownIssue\s*\(", code):
        reason = next((value for start, _, value in literals
                       if start >= match.end() and not code[match.end():start].strip()), "")
        link = ISSUE_URL.search(reason)
        if not link or not re.search(r"\w", ISSUE_URL.sub("", reason)):
            yield source.count("\n", 0, match.start()) + 1, "known-issue"

    # Flag swallowed requirements and explicit retry intent. Ordinary
    # table-driven assertions and repeated edits are independent cases.
    for match in re.finditer(r"\b(?:for\s+[^{};\n]+?\s+in|while\s+|repeat\s*)[^{};]*{", code):
        body = code[match.end():closing_brace(code, match.end() - 1)]
        retry_loop = re.search(r"\b\w*(?:[Aa]ttempt|[Rr]etr)\w*\b", match[0])
        swallowed = re.search(r"\btry\s*\?\s*#require\s*\(", body) or re.search(
            r"\bdo\s*{[^{}]*#require\s*\([^{}]*}\s*catch\s*{\s*(?:continue\b|})", body
        )
        abandons_attempt = re.search(r"\b(?:catch|break|continue)\b|\btry\s*\?", body)
        if swallowed or (retry_loop and abandons_attempt and ASSERTION.search(body)):
            yield source.count("\n", 0, match.start()) + 1, "assertion-retry"

    # Names alone are insufficient: require a conforming/subclassed type with
    # behavior-bearing methods. Void recording methods and overrides that
    # call through to the superclass are allowed.
    for match in SWIFT_DOUBLE.finditer(code):
        body = code[match.end():closing_brace(code, match.end() - 1)]
        methods = re.finditer(r"\b(override\s+)?func\s+(\w+)\b([^{}]*){", body)
        for method in methods:
            override, name, signature = method.groups()
            method_body = body[method.end():closing_brace(body, method.end() - 1)]
            if override and re.search(rf"\bsuper\s*\.\s*{name}\s*\(", method_body):
                continue
            result = signature.rpartition("->")[2].strip()
            returns_value = "->" in signature and result not in {"Void", "()"}
            if override or returns_value or re.search(r"\bthrows\b", signature):
                yield source.count("\n", 0, match.start()) + 1, "test-double"
                break


def qualified_name(node):
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return f"{qualified_name(node.value)}.{node.attr}"
    return ""


def python_violations(source):
    tree = ast.parse(source)
    aliases = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for name in node.names:
                if name.asname:
                    aliases[name.asname] = name.name
        elif isinstance(node, ast.ImportFrom) and node.module:
            for name in node.names:
                aliases[name.asname or name.name] = f"{node.module}.{name.name}"

    def resolved(node):
        name = qualified_name(node)
        first, dot, rest = name.partition(".")
        return aliases.get(first, first) + dot + rest

    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and resolved(node.func) in {"time.sleep", "asyncio.sleep"}:
            yield node.lineno, "fixed-wait"
        if isinstance(node, ast.ClassDef) and node.bases and re.fullmatch(DOUBLE_NAME, node.name):
            methods = (member for member in node.body if isinstance(member, (ast.FunctionDef, ast.AsyncFunctionDef)))
            # A constructor setting up recordings or a method with an empty
            # return is not sufficient evidence of substituted behavior.
            if any(isinstance(value, ast.Raise) or isinstance(value, ast.Return) and value.value is not None
                   for method in methods if method.name != "__init__" for value in ast.walk(method)):
                yield node.lineno, "test-double"
        if isinstance(node, (ast.For, ast.AsyncFor, ast.While)):
            catches_assertion = any(
                isinstance(handler, ast.ExceptHandler)
                and (qualified_name(handler.type) in {"AssertionError", "builtins.AssertionError"}
                     or isinstance(handler.type, ast.Tuple) and any(
                         qualified_name(error) == "AssertionError" for error in handler.type.elts))
                for handler in ast.walk(node)
            )
            if catches_assertion and any(
                isinstance(child, ast.Assert)
                or isinstance(child, ast.Call) and re.search(r"\.(?:assert\w+|fail)$", qualified_name(child.func))
                for child in ast.walk(node)
            ):
                yield node.lineno, "assertion-retry"


def scan(root):
    findings = {}
    for path in sorted((root / "Tests").rglob("*")):
        scanner = {".swift": swift_violations, ".py": python_violations}.get(path.suffix)
        if path.is_file() and scanner:
            violations = sorted(scanner(path.read_text(encoding="utf-8")))
            if violations:
                findings[path.relative_to(root).as_posix()] = violations
    return findings


def read_allowlist(path):
    def unique_object(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError(f"duplicate allowance {key!r}")
            result[key] = value
        return result

    allowances = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    if not isinstance(allowances, dict):
        raise ValueError("expected an object of test paths and rule counts")
    for file, counts in allowances.items():
        if not isinstance(counts, dict) or not counts:
            raise ValueError(f"{file}: remove empty or invalid allowance")
        for rule, count in counts.items():
            if rule not in MESSAGES or type(count) is not int or count <= 0:
                raise ValueError(f"{file}: {rule!r} must name a rule with a positive integer count")
    return allowances


def check(findings, allowances):
    for path in sorted(findings.keys() | allowances.keys()):
        violations = findings.get(path, ())
        actual = Counter(rule for _, rule in violations)
        expected = allowances.get(path, {})
        for rule in sorted(actual.keys() | expected.keys()):
            found, allowed = actual[rule], expected.get(rule, 0)
            if found > allowed:
                yield f"{path}: [{rule}] found {found}, allowance is {allowed}. {MESSAGES[rule]}"
                for line, violation in violations:
                    if violation == rule:
                        yield f"  {path}:{line}"
            elif found < allowed:
                yield (f"{path}: [{rule}] found {found}, allowance is {allowed}. "
                       f"Lower the allowance to {found} (remove the rule or file entry when empty).")


def main():
    root = Path(__file__).resolve().parents[1]
    try:
        findings = scan(root)
        allowances = read_allowlist(root / "Scripts/test-lint-allowlist.json")
        errors = list(check(findings, allowances))
    except (SyntaxError, ValueError, OSError) as error:
        print(f"Test honesty lint: {error}", file=sys.stderr)
        return 1
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Test honesty lint passed ({sum(map(len, findings.values()))} existing allowances)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
