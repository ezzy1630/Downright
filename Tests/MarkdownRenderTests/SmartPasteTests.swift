import Foundation
import MarkdownCore
import Testing

@testable import MarkdownRender

@Suite struct SmartPastePolicyTests {

    @Test func urlUsesSelectionOrAutolink() {
        let selected = MarkdownSmartPaste.replacement(
            for: .url("https://example.com"), selection: "the docs", context: .markdown)
        let empty = MarkdownSmartPaste.replacement(
            for: .url("https://example.com"), selection: "", context: .markdown)

        #expect(selected == "[the docs](https://example.com)")
        #expect(empty == "<https://example.com>")
    }

    @Test func htmlAndTabsUseMarkdownConversions() {
        let html = MarkdownSmartPaste.replacement(
            for: .html("<p><strong>Bold</strong></p>", fallback: "Bold"),
            selection: "", context: .markdown)
        let table = MarkdownSmartPaste.replacement(
            for: .text("Name\tCount\nAda\t1"), selection: "", context: .markdown)

        #expect(html == "**Bold**")
        #expect(table.contains("| Name"))
        #expect(table.contains("| Ada"))
    }

    @Test func htmlDoesNotRequirePlainTextFallback() {
        #expect(MarkdownSmartPaste.replacement(
            for: .html("<p>Only HTML</p>", fallback: ""),
            selection: "", context: .markdown) == "Only HTML")
    }

    @Test func ordinaryTextStaysPlain() {
        let text = "just prose"
        #expect(MarkdownSmartPaste.replacement(
            for: .text(text), selection: "", context: .markdown) == text)
    }

    @Test func literalContextsDoNotTransform() {
        let html = MarkdownSmartPaste.replacement(
            for: .html("<p><strong>Bold</strong></p>", fallback: "Bold"),
            selection: "", context: .code)
        let tabs = MarkdownSmartPaste.replacement(
            for: .text("a\tb\n1\t2"), selection: "", context: .plain)

        #expect(html == "Bold")
        #expect(tabs == "a\tb\n1\t2")
    }

    @Test func codeBlockContextIsDetectedInSourceCoordinates() {
        let source = "Before\n\n```swift\nlet value = 1\n```\n"
        let document = MarkdownParser.parse(source)
        let caret = (source as NSString).range(of: "let value").location

        #expect(MarkdownSmartPaste.context(
            for: NSRange(location: caret, length: 0), in: document) == .code)
        #expect(MarkdownSmartPaste.context(
            for: NSRange(location: 0, length: 6), in: document) == .markdown)
        #expect(MarkdownSmartPaste.context(
            for: NSRange(location: 0, length: 6), in: document, mode: .source) == .plain)
    }
}
