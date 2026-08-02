import Foundation
import Testing
@testable import MarkdownRender

/// One `text -> token` claim about a snippet.
private struct TokenExpectation: Sendable {
    var text: String
    var token: SyntaxToken
    /// Which occurrence of `text` in the snippet, when it appears more than once.
    var occurrence: Int = 0
}

private struct LanguageSnippet: Sendable {
    var language: String
    var code: String
    var expectations: [TokenExpectation]
}

@Suite("Syntax highlighting (§11.3)")
struct SyntaxTests {

    private let highlighter = BuiltinSyntaxHighlighter.shared

    // MARK: - Language registry

    @Test("Supported languages cover the spec list")
    func supportedLanguagesCoverTheSpecList() {
        let required = [
            "swift", "typescript", "javascript", "tsx", "jsx", "python", "rust", "go", "ruby",
            "java", "c", "cpp", "objc", "bash", "json", "yaml", "toml", "sql", "html", "css",
            "xml", "markdown", "diff", "plaintext",
        ]
        let supported = Set(BuiltinSyntaxHighlighter.supportedLanguages)
        for language in required {
            #expect(supported.contains(language), "missing language: \(language)")
        }
        #expect(supported.count == BuiltinSyntaxHighlighter.supportedLanguages.count, "duplicate canonical name")
    }

    @Test("Aliases resolve to canonical names")
    func aliasesResolve() {
        let expected: [String: String] = [
            "ts": "typescript", "TS": "typescript", "js": "javascript", "sh": "bash",
            "zsh": "bash", "shell": "bash", "py": "python", "rs": "rust", "rb": "ruby",
            "yml": "yaml", "c++": "cpp", "objective-c": "objc", "golang": "go",
            "md": "markdown", "patch": "diff", "txt": "plaintext", " Swift ": "swift",
        ]
        for (alias, canonical) in expected {
            #expect(BuiltinSyntaxHighlighter.canonicalLanguage(alias) == canonical, "alias \(alias)")
        }
        #expect(BuiltinSyntaxHighlighter.canonicalLanguage("brainfuck") == nil)
        #expect(BuiltinSyntaxHighlighter.canonicalLanguage("") == nil)
        #expect(highlighter.supports(language: "TSX"))
        #expect(!highlighter.supports(language: "cobol"))
    }

    /// Guessing a language colours the wrong words confidently, so an unknown
    /// one produces nothing at all.
    @Test("Unknown and absent languages produce no runs")
    func unknownLanguagesProduceNoRuns() {
        #expect(highlighter.highlight("let x = 1", language: nil).isEmpty)
        #expect(highlighter.highlight("let x = 1", language: "cobol").isEmpty)
        #expect(highlighter.highlight("plain words", language: "plaintext").isEmpty)
        #expect(highlighter.highlight("", language: "swift").isEmpty)
    }

    // MARK: - Per-language classification

    @Test("Realistic snippets classify correctly, per language")
    func languageSnippets() {
        for snippet in SyntaxTests.snippets {
            let runs = highlighter.highlight(snippet.code, language: snippet.language)
            expectRunInvariants(runs, in: snippet.code, language: snippet.language)
            #expect(!runs.isEmpty, "\(snippet.language) produced no runs")
            for expectation in snippet.expectations {
                expectToken(
                    expectation.text, is: expectation.token, occurrence: expectation.occurrence,
                    in: snippet.code, runs: runs, language: snippet.language
                )
            }
        }
    }

    // MARK: - The cases that separate a lexer from a pile of regexes

    @Test("A comment marker inside a string does not open a comment")
    func commentMarkersInsideStrings() {
        let cases: [(language: String, code: String, literal: String)] = [
            ("swift", #"let s = "a // b /* c */ d""#, #""a // b /* c */ d""#),
            ("python", "s = 'a # b'", "'a # b'"),
            ("bash", #"echo "hash # inside string""#, #""hash # inside string""#),
            ("sql", "SELECT 'a -- b'", "'a -- b'"),
        ]
        for (language, code, literal) in cases {
            let runs = highlighter.highlight(code, language: language)
            expectToken(literal, is: .string, in: code, runs: runs, language: language)
            #expect(
                !runs.contains { $0.token == .comment },
                "\(language): a comment marker inside a string opened a comment"
            )
        }
    }

    @Test("A quote inside a comment does not open a string")
    func quotesInsideComments() {
        let code = """
        // he said "hi and never closed it
        let x = 1
        """
        let runs = highlighter.highlight(code, language: "swift")
        expectToken(#"// he said "hi and never closed it"#, is: .comment, in: code, runs: runs, language: "swift")
        expectToken("let", is: .keyword, in: code, runs: runs, language: "swift")
        #expect(!runs.contains { $0.token == .string }, "a quote inside a comment opened a string")
    }

    @Test("Block comments nest only where the language nests them")
    func nestedBlockComments() {
        let swift = "/* outer /* inner */ still outer */ let x = 1"
        var runs = highlighter.highlight(swift, language: "swift")
        expectToken("/* outer /* inner */ still outer */", is: .comment, in: swift, runs: runs, language: "swift")
        expectToken("let", is: .keyword, in: swift, runs: runs, language: "swift")

        // C does not nest: the first `*/` closes it, and `int` is code again.
        let c = "/* outer /* inner */ int x;"
        runs = highlighter.highlight(c, language: "c")
        expectToken("/* outer /* inner */", is: .comment, in: c, runs: runs, language: "c")
        expectToken("int", is: .type, in: c, runs: runs, language: "c")
    }

    @Test("Python triple-quoted strings and f-strings")
    func pythonStrings() {
        let code = """
        def f(x):
            \"\"\"Doc with # not a comment and 'quotes'.\"\"\"
            return f"value {x}"  # real comment
        """
        let runs = highlighter.highlight(code, language: "python")
        expectToken(
            "\"\"\"Doc with # not a comment and 'quotes'.\"\"\"",
            is: .string, in: code, runs: runs, language: "python"
        )
        expectToken(#"f"value {x}""#, is: .string, in: code, runs: runs, language: "python")
        expectToken("# real comment", is: .comment, in: code, runs: runs, language: "python")
        expectToken("def", is: .keyword, in: code, runs: runs, language: "python")
    }

    @Test("Swift and Rust raw strings")
    func rawStrings() {
        let swift = ##"let s = #"a "quoted" thing"# + "plain""##
        var runs = highlighter.highlight(swift, language: "swift")
        expectToken(##"#"a "quoted" thing"#"##, is: .string, in: swift, runs: runs, language: "swift")
        expectToken(#""plain""#, is: .string, in: swift, runs: runs, language: "swift")

        let rust = ##"let s = r#"say "hi""#; let b = b"bytes";"##
        runs = highlighter.highlight(rust, language: "rust")
        expectToken(##"r#"say "hi""#"##, is: .string, in: rust, runs: runs, language: "rust")
        expectToken(#"b"bytes""#, is: .string, in: rust, runs: runs, language: "rust")
    }

    @Test("Rust lifetimes are not character literals")
    func rustLifetimes() {
        let code = "fn take<'a>(s: &'a str) -> char { 'x' }"
        let runs = highlighter.highlight(code, language: "rust")
        expectToken("'a", is: .keyword, occurrence: 0, in: code, runs: runs, language: "rust")
        expectToken("'a", is: .keyword, occurrence: 1, in: code, runs: runs, language: "rust")
        expectToken("'x'", is: .string, in: code, runs: runs, language: "rust")
        expectToken("str", is: .type, in: code, runs: runs, language: "rust")
    }

    @Test("Shell `#` opens a comment only at a word start")
    func shellHashRules() {
        let code = """
        name=${USER#prefix}
        echo $name  # trailing comment
        """
        let runs = highlighter.highlight(code, language: "bash")
        expectToken("${USER#prefix}", is: .variable, in: code, runs: runs, language: "bash")
        expectToken("# trailing comment", is: .comment, in: code, runs: runs, language: "bash")
        #expect(runs.filter { $0.token == .comment }.count == 1)
    }

    @Test("`diff` fences get real diff colouring")
    func diffColouring() {
        let code = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@
         context stays plain
        -removed line
        +added line
        """
        let runs = highlighter.highlight(code, language: "diff")
        expectRunInvariants(runs, in: code, language: "diff")
        for header in ["diff --git a/a.txt b/a.txt", "--- a/a.txt", "+++ b/a.txt", "@@ -1,3 +1,3 @@"] {
            expectToken(header, is: .diffHeader, in: code, runs: runs, language: "diff")
        }
        expectToken("-removed line", is: .diffRemoved, in: code, runs: runs, language: "diff")
        expectToken("+added line", is: .diffAdded, in: code, runs: runs, language: "diff")
        expectToken(" context stays plain", is: .plain, in: code, runs: runs, language: "diff")
    }

    @Test("A surrogate pair is never split across two runs")
    func multiByteCharacters() {
        let code = "let 🎉 = \"party 🎉 time\""
        let runs = highlighter.highlight(code, language: "swift")
        expectRunInvariants(runs, in: code, language: "swift")
        let units = Array(code.utf16)
        for run in runs where run.range.location > 0 {
            let previous = units[run.range.location - 1]
            #expect(!(previous >= 0xD800 && previous <= 0xDBFF), "a run starts inside a surrogate pair")
        }
    }

    // MARK: - Invariants

    /// Runs must be ascending, non-overlapping, non-empty, and inside the input:
    /// the decoration engine applies them in order and neither sorts nor clamps.
    private func expectRunInvariants(
        _ runs: [SyntaxRun], in code: String, language: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let length = (code as NSString).length
        var previousEnd = 0
        for run in runs {
            #expect(run.range.location >= previousEnd, "\(language): runs overlap or descend", sourceLocation: sourceLocation)
            #expect(run.range.length > 0, "\(language): empty run", sourceLocation: sourceLocation)
            #expect(run.range.upperBound <= length, "\(language): run past the end of the input", sourceLocation: sourceLocation)
            previousEnd = run.range.upperBound
        }
    }

    private func expectToken(
        _ text: String, is expected: SyntaxToken, occurrence: Int = 0,
        in code: String, runs: [SyntaxRun], language: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let target = SyntaxTests.range(of: text, occurrence: occurrence, in: code) else {
            Issue.record(
                "\(language): the snippet has fewer than \(occurrence + 1) copies of \(text)",
                sourceLocation: sourceLocation
            )
            return
        }
        guard let run = runs.first(where: { NSIntersectionRange($0.range, target).length == target.length }) else {
            let overlapping = runs
                .filter { NSIntersectionRange($0.range, target).length > 0 }
                .map { "\($0.token) \(NSStringFromRange($0.range))" }
                .joined(separator: ", ")
            Issue.record(
                "\(language): no single run covers \(text) at \(NSStringFromRange(target)); overlapping: [\(overlapping)]",
                sourceLocation: sourceLocation
            )
            return
        }
        #expect(run.token == expected, "\(language): \(text)", sourceLocation: sourceLocation)
    }

    private static func range(of text: String, occurrence: Int, in code: String) -> NSRange? {
        let haystack = code as NSString
        var searchStart = 0
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            guard searchStart <= haystack.length else { return nil }
            found = haystack.range(
                of: text, options: [.literal],
                range: NSRange(location: searchStart, length: haystack.length - searchStart)
            )
            guard found.location != NSNotFound else { return nil }
            searchStart = found.location + max(1, found.length)
        }
        return found
    }

    // MARK: - Table

    private static let snippets: [LanguageSnippet] = [
        LanguageSnippet(language: "swift", code: """
        // A greeting.
        @MainActor
        struct Greeter {
            let name = "world // not a comment"
            func greet() -> Int { 42 }
        }
        """, expectations: [
            .init(text: "// A greeting.", token: .comment),
            .init(text: "@MainActor", token: .attribute),
            .init(text: "struct", token: .keyword),
            .init(text: "Greeter", token: .type),
            .init(text: #""world // not a comment""#, token: .string),
            // Occurrence 1: "greet" also appears inside "// A greeting.".
            .init(text: "greet", token: .function, occurrence: 1),
            .init(text: "Int", token: .type),
            .init(text: "42", token: .number),
        ]),

        LanguageSnippet(language: "typescript", code: """
        export interface User { id: number }
        const greet = (u: User): string => `hi ${u.id}`;
        """, expectations: [
            .init(text: "export", token: .keyword),
            .init(text: "interface", token: .keyword),
            .init(text: "number", token: .type),
            .init(text: "User", token: .type),
            .init(text: "const", token: .keyword),
            .init(text: "`hi ${u.id}`", token: .string),
        ]),

        LanguageSnippet(language: "javascript", code: """
        const MAX = 10;
        export default function run(items) { return items.map(x => x * MAX); }
        """, expectations: [
            .init(text: "const", token: .keyword),
            .init(text: "MAX", token: .constant),
            .init(text: "10", token: .number),
            .init(text: "run", token: .function),
        ]),

        LanguageSnippet(language: "python", code: """
        import math

        def area(r: float) -> float:
            return math.pi * r ** 2  # circle
        """, expectations: [
            .init(text: "import", token: .keyword),
            .init(text: "def", token: .keyword),
            .init(text: "area", token: .function),
            .init(text: "float", token: .type),
            .init(text: "2", token: .number),
            .init(text: "# circle", token: .comment),
        ]),

        LanguageSnippet(language: "rust", code: """
        #[derive(Debug)]
        pub struct Point { x: f64 }

        impl Point {
            pub fn origin() -> Self { Point { x: 0.0 } }
        }
        """, expectations: [
            .init(text: "#[derive(Debug)]", token: .attribute),
            .init(text: "pub", token: .keyword),
            .init(text: "struct", token: .keyword),
            .init(text: "f64", token: .type),
            .init(text: "origin", token: .function),
            .init(text: "0.0", token: .number),
        ]),

        LanguageSnippet(language: "go", code: """
        package main

        func Sum(xs []int) int {
            raw := `line one
        line two`
            _ = raw
            return 0
        }
        """, expectations: [
            .init(text: "package", token: .keyword),
            .init(text: "func", token: .keyword),
            .init(text: "int", token: .type),
            .init(text: "`line one\nline two`", token: .string),
            .init(text: "Sum", token: .function),
        ]),

        LanguageSnippet(language: "ruby", code: """
        class Greeter
          def greet(name)
            @count += 1
            puts "hello #{name} # not a comment"  # real comment
          end
        end
        """, expectations: [
            .init(text: "class", token: .keyword),
            .init(text: "Greeter", token: .type),
            .init(text: "@count", token: .variable),
            .init(text: #""hello #{name} # not a comment""#, token: .string),
            .init(text: "# real comment", token: .comment),
            .init(text: "greet", token: .function),
        ]),

        LanguageSnippet(language: "java", code: """
        public class Main {
            private static final int MAX_SIZE = 10;
            @Override public String toString() { return "x"; }
        }
        """, expectations: [
            .init(text: "public", token: .keyword),
            .init(text: "MAX_SIZE", token: .constant),
            .init(text: "int", token: .type),
            .init(text: "@Override", token: .attribute),
            .init(text: "String", token: .type),
            .init(text: "toString", token: .function),
        ]),

        LanguageSnippet(language: "c", code: """
        #include <stdio.h>

        int main(void) {
            printf("%d\\n", 42);
            return 0;
        }
        """, expectations: [
            .init(text: "#include", token: .attribute),
            .init(text: "int", token: .type),
            .init(text: "void", token: .type),
            .init(text: "printf", token: .function),
            .init(text: "42", token: .number),
        ]),

        LanguageSnippet(language: "cpp", code: """
        auto s = R"json({"a": 1})json";
        constexpr int kMax = 3;
        """, expectations: [
            .init(text: #"R"json({"a": 1})json""#, token: .string),
            .init(text: "constexpr", token: .keyword),
            .init(text: "int", token: .type),
            .init(text: "3", token: .number),
        ]),

        LanguageSnippet(language: "objc", code: """
        @interface Greeter : NSObject
        @end

        NSString *greeting = @"hi";
        """, expectations: [
            .init(text: "@interface", token: .attribute),
            .init(text: "NSObject", token: .type),
            .init(text: "NSString", token: .type),
            .init(text: #"@"hi""#, token: .string),
        ]),

        LanguageSnippet(language: "bash", code: """
        #!/usr/bin/env bash
        set -euo pipefail
        for f in *.md; do
          echo "found $f"
        done
        """, expectations: [
            .init(text: "#!/usr/bin/env bash", token: .comment),
            .init(text: "for", token: .keyword),
            .init(text: "do", token: .keyword),
            .init(text: "echo", token: .function),
            .init(text: #""found $f""#, token: .string),
        ]),

        LanguageSnippet(language: "json", code: """
        {"name": "downright", "version": 2, "ok": true, "extra": null}
        """, expectations: [
            .init(text: #""name""#, token: .attribute),
            .init(text: #""downright""#, token: .string),
            .init(text: "2", token: .number),
            .init(text: "true", token: .constant),
            .init(text: "null", token: .constant),
        ]),

        LanguageSnippet(language: "yaml", code: """
        name: downright  # a comment
        items:
          - one
          - "two: not a key"
        """, expectations: [
            .init(text: "name", token: .attribute),
            .init(text: "items", token: .attribute),
            .init(text: "# a comment", token: .comment),
            .init(text: #""two: not a key""#, token: .string),
        ]),

        LanguageSnippet(language: "toml", code: """
        [package]
        name = "downright"
        edition = 2021
        """, expectations: [
            .init(text: "[package]", token: .type),
            .init(text: "name", token: .attribute),
            .init(text: #""downright""#, token: .string),
            .init(text: "2021", token: .number),
        ]),

        LanguageSnippet(language: "sql", code: """
        -- find people
        SELECT id, name FROM users WHERE name = 'O''Brien';
        """, expectations: [
            .init(text: "-- find people", token: .comment),
            .init(text: "SELECT", token: .keyword),
            .init(text: "FROM", token: .keyword),
            .init(text: "'O''Brien'", token: .string),
        ]),

        LanguageSnippet(language: "css", code: """
        /* heading */
        .title { color: #ff0000; margin: -5px; }
        """, expectations: [
            .init(text: "/* heading */", token: .comment),
            .init(text: "color", token: .attribute),
            .init(text: "#ff0000", token: .constant),
            .init(text: "5px", token: .number),
        ]),

        LanguageSnippet(language: "html", code: """
        <!-- note -->
        <div class="a">text &amp; more</div>
        """, expectations: [
            .init(text: "<!-- note -->", token: .comment),
            .init(text: "div", token: .type),
            .init(text: "class", token: .attribute),
            .init(text: #""a""#, token: .string),
            .init(text: "&amp;", token: .constant),
        ]),

        LanguageSnippet(language: "xml", code: """
        <?xml version="1.0"?>
        <root><item id="1">v</item></root>
        """, expectations: [
            .init(text: #"<?xml version="1.0"?>"#, token: .attribute),
            .init(text: "root", token: .type),
            .init(text: "id", token: .attribute),
            .init(text: #""1""#, token: .string),
        ]),

        LanguageSnippet(language: "jsx", code: """
        export default function App() {
          return <div className="app">{title}</div>;
        }
        """, expectations: [
            .init(text: "export", token: .keyword),
            .init(text: "function", token: .keyword),
            .init(text: "App", token: .function),
            .init(text: #""app""#, token: .string),
        ]),

        LanguageSnippet(language: "tsx", code: """
        const Panel = (props: Props): JSX.Element => <section>{props.title}</section>;
        """, expectations: [
            .init(text: "const", token: .keyword),
            .init(text: "Props", token: .type),
            .init(text: "section", token: .plain),
        ]),

        LanguageSnippet(language: "markdown", code: """
        # Title

        Some *emphasis* and `code`.

        - item [link](https://example.com)

        ```swift
        let x = 1
        ```
        """, expectations: [
            .init(text: "# Title", token: .keyword),
            .init(text: "`code`", token: .string),
            .init(text: "(https://example.com)", token: .string),
            .init(text: "```swift", token: .attribute),
            .init(text: "let x = 1", token: .string),
        ]),
    ]
}
