import Foundation
import Testing
@testable import MarkdownCore

// §4.1: each extension is a small, independently testable AST transform.

@Suite struct FrontMatterTests {

    @Test func parsesScalarsQuotesAndInlineLists() {
        let doc = MarkdownParser.parse("""
        ---
        title: Release Plan
        owner: "Ada Lovelace"
        tags: [alpha, beta]
        count: 3
        ---

        # Body
        """)
        let front = doc.frontMatter
        #expect(front != nil)
        #expect(front?["title"] == "Release Plan")
        #expect(front?["owner"] == "Ada Lovelace")
        #expect(front?["tags"] == "alpha, beta")
        #expect(front?["count"] == "3")
        #expect(doc.substring(front!.range) == "---\ntitle: Release Plan\nowner: \"Ada Lovelace\"\ntags: [alpha, beta]\ncount: 3\n---\n")
    }

    @Test func parsesBlockSequences() {
        let doc = MarkdownParser.parse("---\ntags:\n  - one\n  - two\nx: y\n---\n\nBody\n")
        #expect(doc.frontMatter?["tags"] == "one, two")
        #expect(doc.frontMatter?["x"] == "y")
    }

    /// The reason front matter is stripped before cmark runs: left in place it
    /// parses as a thematic break plus a setext H2.
    @Test func bodyAfterFrontMatterParsesWithCorrectRanges() {
        let text = "---\ntitle: X\n---\n\n# Heading\n\nBody.\n"
        let doc = MarkdownParser.parse(text)
        #expect(doc.headings.count == 1)
        #expect(doc.headings[0].level == 1)
        #expect(doc.substring(doc.headings[0].range) == "# Heading")
        // No thematic break should have been produced by the fences.
        var breaks = 0
        doc.root.walk { if case .thematicBreak = $0.content { breaks += 1 } }
        #expect(breaks == 0)
    }

    @Test func onlyMatchesOnTheVeryFirstLine() {
        #expect(MarkdownParser.parse("\n---\ntitle: X\n---\n").frontMatter == nil)
        #expect(MarkdownParser.parse("# H\n\n---\ntitle: X\n---\n").frontMatter == nil)
        #expect(MarkdownParser.parse("---\nno closing fence\n").frontMatter == nil)
    }

    @Test func ignoresWhatItCannotParseRatherThanFailing() {
        let doc = MarkdownParser.parse("---\nnested:\n  deep:\n    value: 1\nok: yes\n---\n\nBody\n")
        #expect(doc.frontMatter != nil)
        #expect(doc.frontMatter?["ok"] == "yes")
    }

    @Test func parsesBlockScalarValues() {
        let doc = MarkdownParser.parse("""
        ---
        summary: |
          first line
          second line
        abstract: >
          folded one
          folded two
        ok: yes
        ---

        Body
        """)
        #expect(doc.frontMatter?["summary"] == "first line\nsecond line")
        #expect(doc.frontMatter?["abstract"] == "folded one folded two")
        #expect(doc.frontMatter?["ok"] == "yes")
    }

    @Test func parsesInlineArrayWithCommasInsideQuotes() {
        let doc = MarkdownParser.parse("""
        ---
        tags: ["alpha, beta", "gamma, delta"]
        title: "Hello, World"
        ---

        Body
        """)
        #expect(doc.frontMatter?["tags"] == "alpha, beta, gamma, delta")
        #expect(doc.frontMatter?["title"] == "Hello, World")
    }
}

@Suite struct MathTests {

    private func inlineMath(_ text: String) -> [String] {
        let doc = MarkdownParser.parse(text)
        var out: [String] = []
        doc.root.walk { block in
            for span in block.inlines {
                span.walk { inline in
                    if case .inlineMath(let latex) = inline.kind { out.append(doc.substring(latex)) }
                }
            }
        }
        return out
    }

    @Test func matchesInlineAndEscapedDelimiters() {
        #expect(inlineMath("Math $x^2$ here\n") == ["x^2"])
        #expect(inlineMath("Math \\(a+b\\) here\n") == ["a+b"])
        #expect(inlineMath("Two $a$ and $b$ here\n") == ["a", "b"])
    }

    /// The cases §4.1 names explicitly.  A false positive turns prose into a
    /// broken glyph, so these matter more than the positives.
    @Test func rejectsShellAndCurrency() {
        #expect(inlineMath("Run `echo $PATH` now\n").isEmpty)
        #expect(inlineMath("Run echo $PATH now\n").isEmpty)
        #expect(inlineMath("It costs $5 and $10\n").isEmpty)
        #expect(inlineMath("Between $100 and $200 total\n").isEmpty)
        #expect(inlineMath("Use $(cmd) and $(other) here\n").isEmpty)
        #expect(inlineMath("A $VAR and $OTHER pair\n").isEmpty)
        #expect(inlineMath("Empty $$ pair\n").isEmpty)
    }

    @Test func neverMatchesInsideCode() {
        #expect(inlineMath("A `$x$` span\n").isEmpty)
        let doc = MarkdownParser.parse("```bash\necho $x$ y\n```\n")
        doc.root.walk { block in
            if case .codeBlock = block.content { #expect(block.inlines.isEmpty) }
        }
    }

    @Test func labelledFormDisplaysOnlyItsLabel() throws {
        let source = "See [[Design Notes|the notes]] here\n"
        let document = MarkdownParser.parse(source)
        let paragraph = try #require(document.root.children.first)
        let span = try #require(paragraph.inlines.first { inline in
            if case .wikilink = inline.kind { return true }
            return false
        })
        #expect((source as NSString).substring(with: span.contentRange) == "the notes")
        #expect((source as NSString).substring(with: try #require(span.leadingMarkerRange)) == "[[Design Notes|")
    }

    @Test func wholeParagraphDisplayMathBecomesABlock() {
        let doc = MarkdownParser.parse("Intro.\n\n$$\ne^{i\\pi} + 1 = 0\n$$\n\nOutro.\n")
        var found: String?
        doc.root.walk { block in
            if case .mathBlock(let latex) = block.content { found = doc.substring(latex) }
        }
        #expect(found?.trimmingCharacters(in: .whitespacesAndNewlines) == "e^{i\\pi} + 1 = 0")
    }

    @Test func mathFencesBecomeMathBlocks() {
        let doc = MarkdownParser.parse("```math\nx = 1\n```\n")
        guard case .mathBlock(let latex) = doc.root.children.first!.content else {
            Issue.record("expected a math block")
            return
        }
        #expect(doc.substring(latex) == "x = 1\n")
    }

    @Test func matrixDoubleBackslashDoesNotTriggerEscapedCloser() {
        let text = "Formula \\( \\begin{pmatrix} 1 \\\\ ) 2 \\end{pmatrix} \\) works\n"
        let matches = inlineMath(text)
        #expect(matches.count == 1)
        #expect(matches[0] == " \\begin{pmatrix} 1 \\\\ ) 2 \\end{pmatrix} ")
    }
}

@Suite struct CalloutTests {

    @Test func recognisesKindAndTitle() {
        let doc = MarkdownParser.parse("> [!WARNING] Be careful\n> The body.\n")
        guard case .callout(let kind, let title) = doc.root.children.first!.content else {
            Issue.record("expected a callout, got \(doc.root.children.first!.content)")
            return
        }
        #expect(kind == .warning)
        #expect(title == "Be careful")
        #expect(doc.substring(doc.root.children[0].markerRange!) == "> [!WARNING] Be careful")
    }

    @Test func handlesMultipleSpacesAndTabsAfterQuoteMarker() {
        let multipleSpaces = MarkdownParser.parse(">  [!NOTE] Spaced\n> Body\n")
        guard case .callout(let kind1, let title1) = multipleSpaces.root.children.first!.content else {
            Issue.record("expected callout for multiple spaces")
            return
        }
        #expect(kind1 == .note)
        #expect(title1 == "Spaced")

        let tabbed = MarkdownParser.parse(">\t[!TIP] Tabbed\n> Body\n")
        guard case .callout(let kind2, let title2) = tabbed.root.children.first!.content else {
            Issue.record("expected callout for tabbed marker")
            return
        }
        #expect(kind2 == .tip)
        #expect(title2 == "Tabbed")
    }

    @Test func isCaseInsensitiveAndTitleIsOptional() {
        for token in ["[!note]", "[!Note]", "[!NOTE]"] {
            let doc = MarkdownParser.parse("> \(token)\n> body\n")
            guard case .callout(let kind, let title) = doc.root.children.first!.content else {
                Issue.record("expected a callout for \(token)")
                continue
            }
            #expect(kind == .note)
            #expect(title == nil)
        }
    }

    @Test func markerTextIsLiftedOutOfTheBody() {
        let doc = MarkdownParser.parse("> [!TIP] Hint\n> Body text.\n")
        let callout = doc.root.children[0]
        #expect(!doc.substring(callout.contentRange).contains("[!TIP]"))
        #expect(doc.substring(callout.contentRange).contains("Body text."))
    }

    @Test func plainQuotesStayQuotes() {
        let doc = MarkdownParser.parse("> just a quote\n")
        guard case .blockQuote = doc.root.children.first!.content else {
            Issue.record("expected a blockquote")
            return
        }
        let unknown = MarkdownParser.parse("> [!NOTAKIND] x\n")
        guard case .blockQuote = unknown.root.children.first!.content else {
            Issue.record("an unknown callout kind must stay a blockquote")
            return
        }
    }
}

@Suite struct WikilinkTests {

    private func wikilinks(_ text: String) -> [(String, String?)] {
        let doc = MarkdownParser.parse(text)
        var out: [(String, String?)] = []
        doc.root.walk { block in
            for span in block.inlines {
                span.walk { inline in
                    if case .wikilink(let target, let label) = inline.kind { out.append((target, label)) }
                }
            }
        }
        return out
    }

    @Test func rejectsWikilinksAcrossLoneCR() {
        let text = "[[Target\rLabel]]"
        #expect(wikilinks(text).isEmpty)
    }

    @Test func matchesBothForms() {
        let plain = wikilinks("See [[Design Notes]] here\n")
        #expect(plain.count == 1)
        #expect(plain[0].0 == "Design Notes")
        #expect(plain[0].1 == nil)

        let labelled = wikilinks("See [[Design Notes|the notes]] here\n")
        #expect(labelled.count == 1)
        #expect(labelled[0].0 == "Design Notes")
        #expect(labelled[0].1 == "the notes")
    }

    @Test func paddedTargetsAndLabelsTrimButKeepGeometry() {
        let padded = wikilinks("See [[ Design Notes | the notes ]] here\n")
        #expect(padded.count == 1)
        #expect(padded[0].0 == "Design Notes")
        #expect(padded[0].1 == "the notes")

        let doc = MarkdownParser.parse("[[  A  ]]\n")
        var span: (NSRange?, NSRange?, NSRange?)?
        doc.root.walk { block in
            for s in block.inlines {
                s.walk { inline in
                    if case .wikilink = inline.kind { span = (inline.leadingMarkerRange, inline.contentRange, inline.trailingMarkerRange) }
                }
            }
        }
        // markers and content must cover the written padding, not the trimmed
        // target: `[[` is a 2-char marker, the body `  A  ` is content.
        let (leading, content, trailing) = span!
        #expect(leading == NSRange(location: 0, length: 2))
        #expect(content == NSRange(location: 2, length: 5))
        #expect(trailing == NSRange(location: 7, length: 2))
    }

    @Test func neverMatchesInsideCode() {
        #expect(wikilinks("A `[[Name]]` span\n").isEmpty)
    }

    @Test func ignoresMalformedBrackets() {
        #expect(wikilinks("A [[unclosed here\n").isEmpty)
        #expect(wikilinks("A [[]] here\n").isEmpty)
    }
}

@Suite struct PathTokenTests {

    private func paths(_ text: String) -> [String] {
        MarkdownParser.parse(text).pathTokens.map(\.token.rawPath)
    }

    @Test func findsPathsWithLineNumbers() {
        let doc = MarkdownParser.parse("Edit src/auth/session.ts:42 next.\n")
        #expect(doc.pathTokens.count == 1)
        #expect(doc.pathTokens[0].token.rawPath == "src/auth/session.ts")
        #expect(doc.pathTokens[0].token.line == 42)
        // The whole token is underlined and opened, `:42` included.
        #expect(doc.substring(doc.pathTokens[0].range) == "src/auth/session.ts:42")
    }

    @Test func findsRelativeAndExtensionOnlyForms() {
        #expect(paths("See ./x/y.md for details.\n") == ["./x/y.md"])
        #expect(paths("Open Package.swift now.\n") == ["Package.swift"])
        #expect(paths("Check src/foo.ts here.\n") == ["src/foo.ts"])
        #expect(paths("Look at ../parent/file.py today.\n") == ["../parent/file.py"])
    }

    @Test func codeSpansRelaxTheShapeRules() {
        let doc = MarkdownParser.parse("Run `docs/plans` for it.\n")
        #expect(doc.pathTokens.count == 1)
        #expect(doc.pathTokens[0].fromCodeSpan)
        #expect(doc.pathTokens[0].token.rawPath == "docs/plans")
    }

    /// §8.4 is a trust instrument: underlining `and/or` would train the user to
    /// ignore the signal, so prose needs a real path shape.
    @Test func rejectsProseThatMerelyContainsASlash() {
        #expect(paths("Use and/or as needed.\n").isEmpty)
        #expect(paths("A read/write lock here.\n").isEmpty)
        #expect(paths("They said he/him plainly.\n").isEmpty)
    }

    @Test func rejectsURLs() {
        #expect(paths("Visit https://example.com/x.md today.\n").isEmpty)
        #expect(paths("Mail mailto:a@b.com now.\n").isEmpty)
        #expect(paths("See www.example.com/a.md here.\n").isEmpty)
    }

    @Test func trimsSentencePunctuation() {
        #expect(paths("Look at src/foo.ts.\n") == ["src/foo.ts"])
        #expect(paths("Files: src/a.ts, src/b.ts.\n") == ["src/a.ts", "src/b.ts"])
    }

    @Test func neverTouchesTheFilesystem() {
        // A path that certainly does not exist still produces a token; the app
        // resolves, not the parser.
        #expect(paths("See imaginary/nowhere/at/all.ts here.\n") == ["imaginary/nowhere/at/all.ts"])
    }

    /// Regression: a non-ASCII character such as an emoji in a code span used
    /// to force-unwrap `UnicodeScalar` on a UTF-16 surrogate half and trap on
    /// the per-keystroke reparse.  It must be skipped, not crash.
    @Test func emojiInCodeSpanDoesNotCrash() {
        #expect(paths("Run `config.🚀` next.\n").isEmpty)
        // A real extension after the emoji still resolves.
        #expect(paths("Edit `src/cache.🚀.ts`.\n") == ["src/cache.🚀.ts"])
    }

    /// Regression: a one-character path before a `:digits` suffix (`3:16`,
    /// `9:30`) used to reach `isURL` with a one-unit range, whose `://` scan
    /// built `start..<(start - 1)` and fatally trapped the per-keystroke
    /// parse.  Ordinary prose times and ratios must simply not be tokens.
    @Test func singleCharacterClockAndRatioTokensDoNotCrash() {
        #expect(paths("John 3:16 says so.\n").isEmpty)
        #expect(paths("Meet at 9:30 sharp.\n").isEmpty)
        #expect(paths("A ratio of 1:2 here.\n").isEmpty)
        #expect(paths("Run `a:1` for it.\n").isEmpty)
        #expect(paths("Verse 2:5 and chapter 3:16 agree.\n").isEmpty)
        // A real path keeps its suffix behaviour after the fix.
        let doc = MarkdownParser.parse("Edit src/auth/session.ts:42 next.\n")
        #expect(doc.pathTokens.first?.token.line == 42)
    }
}

@Suite struct FenceLanguageTests {

    @Test func mermaidBecomesADiagram() {
        let doc = MarkdownParser.parse("```mermaid\ngraph TD;\nA-->B;\n```\n")
        guard case .mermaid(let source) = doc.root.children.first!.content else {
            Issue.record("expected a mermaid block")
            return
        }
        #expect(doc.substring(source) == "graph TD;\nA-->B;\n")
    }

    @Test func diffKeepsItsLanguageAndStaysCode() {
        let doc = MarkdownParser.parse("```diff\n- a\n+ b\n```\n")
        guard case .codeBlock(let language, _, _) = doc.root.children.first!.content else {
            Issue.record("expected a code block")
            return
        }
        #expect(language == "diff")
    }

    @Test func guessesOnlyWhenConfident() {
        #expect(FenceLanguage.guess(from: "#!/usr/bin/env python\nprint(1)\n") == "python")
        #expect(FenceLanguage.guess(from: "func f() -> Int { 1 }\nguard x else { }\n") == "swift")
        #expect(FenceLanguage.guess(from: "def f(self):\n    import os\n") == "python")
        #expect(FenceLanguage.guess(from: "const x = 1;\nfunction f() {}\n") == "javascript")
        #expect(FenceLanguage.guess(from: "<div>\n</div>\n") == "html")
        #expect(FenceLanguage.guess(from: "$ ls -la\n$ cd /tmp\n") == "bash")
        #expect(FenceLanguage.guess(from: "just some prose here\nnothing to see\n") == nil)
        #expect(FenceLanguage.guess(from: "") == nil)
    }
}
