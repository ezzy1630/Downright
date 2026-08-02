import Foundation
import Testing
@testable import MarkdownCore

@Suite struct ListEditingTests {

    private func pressReturn(_ text: String, at offset: Int) -> String? {
        let doc = MarkdownParser.parse(text)
        guard let continuation = ListEditing.continuation(doc, at: offset) else { return nil }
        let ns = NSMutableString(string: text)
        ns.replaceCharacters(in: continuation.replaceRange, with: continuation.insertion)
        return ns as String
    }

    @Test func continuesABulletList() {
        // Caret at the end of "- one".
        #expect(pressReturn("- one\n- two\n", at: 5) == "- one\n- \n- two\n")
    }

    @Test func continuesAnOrderedList() {
        #expect(pressReturn("1. one\n", at: 6) == "1. one\n2. \n")
        #expect(pressReturn("3) three\n", at: 8) == "3) three\n4) \n")
    }

    @Test func continuesATaskList() {
        #expect(pressReturn("- [x] done\n", at: 10) == "- [x] done\n- [ ] \n")
    }

    @Test func keepsNestedIndentation() {
        #expect(pressReturn("- top\n  - nested\n", at: 16) == "- top\n  - nested\n  - \n")
    }

    /// §6.4: "outdent-and-exit on an empty item."
    @Test func emptyItemAtTopLevelExitsTheList() {
        #expect(pressReturn("- one\n- \n", at: 8) == "- one\n\n")
    }

    @Test func emptyNestedItemOutdents() {
        // `- top` / `  - ` would be a setext H2, not a nested item, so the
        // fixture needs a real nested list above the empty one.
        #expect(pressReturn("- top\n  - a\n  - \n", at: 16) == "- top\n  - a\n- \n")
    }

    @Test func returnsNilOutsideAList() {
        #expect(ListEditing.continuation(MarkdownParser.parse("Just prose.\n"), at: 4) == nil)
        #expect(ListEditing.continuation(MarkdownParser.parse("```\ncode\n```\n"), at: 6) == nil)
    }

    @Test func indentsAndOutdentsListLines() {
        let text = "- one\n- two\n"
        let doc = MarkdownParser.parse(text)
        let second = doc.range(ofLine: 2)
        let indented = ListEditing.indent(doc, lineRange: second, outdent: false).applied(to: text)
        #expect(indented == "- one\n  - two\n")

        let back = ListEditing.indent(
            MarkdownParser.parse(indented), lineRange: NSRange(location: 6, length: 7), outdent: true
        ).applied(to: indented)
        #expect(back == text)
    }

    @Test func indentUsesTheMarkerWidth() {
        let text = "1. one\n2. two\n"
        let doc = MarkdownParser.parse(text)
        let indented = ListEditing.indent(doc, lineRange: doc.range(ofLine: 2), outdent: false)
            .applied(to: text)
        #expect(indented == "1. one\n   2. two\n")
    }

    @Test func outdentAtColumnZeroIsANoOp() {
        let text = "- one\n"
        let doc = MarkdownParser.parse(text)
        #expect(ListEditing.indent(doc, lineRange: doc.range(ofLine: 1), outdent: true).isEmpty)
    }

    @Test func indentSpansMultipleLines() {
        let text = "- a\n- b\n- c\n"
        let doc = MarkdownParser.parse(text)
        let edits = ListEditing.indent(doc, lineRange: NSRange(location: 4, length: 8), outdent: false)
        #expect(edits.applied(to: text) == "- a\n  - b\n  - c\n")
    }
}

@Suite struct SmartPasteTests {

    @Test func linkifiesASelection() {
        #expect(SmartPaste.linkified(selection: "the docs", url: "https://example.com")
            == "[the docs](https://example.com)")
        #expect(SmartPaste.linkified(selection: "", url: "https://example.com")
            == "<https://example.com>")
        #expect(SmartPaste.linkified(selection: "mail me", url: "mailto:a@b.com")
            == "[mail me](mailto:a@b.com)")
        #expect(SmartPaste.linkified(selection: "x", url: "www.example.com")
            == "[x](https://www.example.com)")
    }

    @Test func refusesNonURLs() {
        #expect(SmartPaste.linkified(selection: "x", url: "just some text") == nil)
        #expect(SmartPaste.linkified(selection: "x", url: "") == nil)
        #expect(SmartPaste.linkified(selection: "x", url: "not-a-url") == nil)
    }

    @Test func escapesBracketsInTheLabel() {
        #expect(SmartPaste.linkified(selection: "a [b] c", url: "https://x.com")
            == "[a \\[b\\] c](https://x.com)")
    }

    @Test func convertsTabSeparatedDataToATable() {
        let out = SmartPaste.markdownTable(forTabSeparated: "Name\tCount\nAda\t1\nGrace\t22\n")
        #expect(out == """
        | Name  | Count |
        | ----- | ----- |
        | Ada   | 1     |
        | Grace | 22    |
        """)
    }

    @Test func escapesPipesInPastedCells() {
        let out = SmartPaste.markdownTable(forTabSeparated: "a|b\tc\n1\t2\n")
        #expect(out?.contains("a\\|b") == true)
    }

    @Test func returnsNilForTextWithoutTabs() {
        #expect(SmartPaste.markdownTable(forTabSeparated: "just\nsome\nlines\n") == nil)
        #expect(SmartPaste.markdownTable(forTabSeparated: "") == nil)
    }

    @Test func convertsHTMLHeadingsParagraphsAndEmphasis() {
        let markdown = SmartPaste.markdown(forHTML:
            "<h2>Title</h2><p>Some <strong>bold</strong> and <em>italic</em> text.</p>")
        #expect(markdown == "## Title\n\nSome **bold** and *italic* text.")
    }

    @Test func convertsHTMLLinksAndImages() {
        #expect(SmartPaste.markdown(forHTML: "<p>See <a href=\"https://x.com\">here</a>.</p>")
            == "See [here](https://x.com).")
        #expect(SmartPaste.markdown(forHTML: "<p><img src=\"a.png\" alt=\"Alt\"></p>")
            == "![Alt](a.png)")
    }

    @Test func convertsHTMLLists() {
        #expect(SmartPaste.markdown(forHTML: "<ul><li>one</li><li>two</li></ul>")
            == "- one\n- two")
        #expect(SmartPaste.markdown(forHTML: "<ol><li>one</li><li>two</li></ol>")
            == "1. one\n2. two")
    }

    @Test func convertsHTMLCodeAndTables() {
        #expect(SmartPaste.markdown(forHTML: "<p>Use <code>x = 1</code> here.</p>")
            == "Use `x = 1` here.")
        let table = SmartPaste.markdown(forHTML:
            "<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>")
        #expect(table == "| A   | B   |\n| --- | --- |\n| 1   | 2   |")
    }

    @Test func decodesEntitiesAndDropsScripts() {
        #expect(SmartPaste.markdown(forHTML: "<p>a &amp; b &lt;c&gt;</p>") == "a & b <c>")
        #expect(SmartPaste.markdown(forHTML: "<script>evil()</script><p>safe</p>") == "safe")
        #expect(SmartPaste.markdown(forHTML: "<style>p{}</style><p>safe</p>") == "safe")
    }

    @Test func unknownTagsDegradeToTheirTextContent() {
        #expect(SmartPaste.markdown(forHTML: "<p>a <mark>highlighted</mark> word</p>")
            == "a highlighted word")
    }
}
