import AppKit
import Foundation
import MarkdownCore
import Testing

@testable import MarkdownRender

private final class UndoManagerHostView: NSView {
    let manager = UndoManager()

    override var undoManager: UndoManager? { manager }
}

@Suite("Smart paste integration", .serialized)
@MainActor
struct SmartPasteIntegrationTests {
    private func isolatedPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("DownrightTests.\(UUID().uuidString)"))
    }

    private func view(for source: String, mode: RenderMode = .live) -> MarkdownTextView {
        let storage = NSTextStorage(string: source)
        let view = MarkdownTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400), storage: storage)
        view.mode = mode
        view.update(document: MarkdownParser.parse(source), dirty: .wholesale)
        return view
    }

    @Test("pasteboard priority prefers URL over HTML and plain text")
    func pasteboardPriority() {
        let pasteboard = isolatedPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("www.example.com", forType: .URL)
        pasteboard.setString("<p>Browser title</p>", forType: .html)
        pasteboard.setString("fallback", forType: .string)

        let payload = MarkdownSmartPaste.payload(from: pasteboard)
        #expect(payload == .url("www.example.com"))
        #expect(MarkdownSmartPaste.replacement(
            for: payload!, selection: "title", context: .markdown)
            == "[title](https://www.example.com)")
        #expect(MarkdownSmartPaste.replacement(
            for: .url("javascript://alert(1)"), selection: "title", context: .markdown)
            == "javascript://alert(1)")
        #expect(MarkdownSmartPaste.replacement(
            for: .url("https://example.com/a(b)"), selection: "title", context: .markdown)
            == "[title](<https://example.com/a(b)>)")
    }

    @Test("HTML-only clipboard converts without a plain fallback")
    func htmlOnlyClipboard() {
        let pasteboard = isolatedPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("<p><strong>Only HTML</strong></p>", forType: .html)

        let payload = MarkdownSmartPaste.payload(from: pasteboard)
        #expect(payload == .html("<p><strong>Only HTML</strong></p>", fallback: ""))
        #expect(MarkdownSmartPaste.replacement(
            for: payload!, selection: "", context: .markdown) == "**Only HTML**")
    }

    @Test("source edit replaces the source selection and creates one undo step")
    func sourceEditAndUndo() {
        let source = "Select this"
        let view = view(for: source)
        let host = UndoManagerHostView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        host.addSubview(view)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true)
        window.contentView = host
        #expect(window.makeFirstResponder(view))
        defer { window.orderOut(nil) }
        view.setSourceSelectedRanges([NSRange(location: 0, length: (source as NSString).length)])

        let pasteboard = isolatedPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("<p><em>replacement</em></p>", forType: .html)
        let payload = MarkdownSmartPaste.payload(from: pasteboard)!
        let replacement = MarkdownSmartPaste.replacement(
            for: payload, selection: source, context: .markdown)
        #expect(view.performSourceEdit(range: view.sourceSelectedRange, replacement: replacement))
        #expect(view.textStorage?.string == "*replacement*")
        #expect(view.sourceSelectedRange == NSRange(location: 13, length: 0))

        let undoManager = view.undoManager
        #expect(undoManager?.canUndo == true)
        undoManager?.undo()
        #expect(view.textStorage?.string == source)
        #expect(undoManager?.canUndo == false)
    }

    @Test("code, math, and front matter keep clipboard text literal")
    func literalContextsBypassTransforms() {
        let html = MarkdownPastePayload.html(
            "<p><strong>literal</strong></p>", fallback: "literal")
        let sources = [
            "```swift\nlet value = 1\n```\n",
            "$$\nx + y\n$$\n",
            "---\ntitle: Draft\n---\n\nBody\n",
        ]
        for source in sources {
            let document = MarkdownParser.parse(source)
            let offset = source.firstIndex(of: "\n").map { source.distance(from: source.startIndex, to: $0) } ?? 0
            let context = MarkdownSmartPaste.context(
                for: NSRange(location: offset, length: 0), in: document)
            #expect(context == .plain || context == .code)
            #expect(MarkdownSmartPaste.replacement(
                for: html, selection: "", context: context) == "literal")
        }
    }

    @Test("inline code and math stay literal at their source spans")
    func inlineLiteralBoundaries() {
        let source = "Before `code` and $x + y$ after"
        let document = MarkdownParser.parse(source)
        let codeStart = (source as NSString).range(of: "`code`").location
        let mathStart = (source as NSString).range(of: "$x + y$").location
        let html = MarkdownPastePayload.html("<strong>changed</strong>", fallback: "changed")

        #expect(MarkdownSmartPaste.context(
            for: NSRange(location: codeStart + 2, length: 0), in: document) == .plain)
        #expect(MarkdownSmartPaste.context(
            for: NSRange(location: codeStart - 1, length: 0), in: document) == .markdown)
        #expect(MarkdownSmartPaste.context(
            for: NSRange(location: mathStart + 2, length: 0), in: document) == .plain)
        #expect(MarkdownSmartPaste.context(
            for: NSRange(location: mathStart - 1, length: 0), in: document) == .markdown)
        #expect(MarkdownSmartPaste.replacement(
            for: html, selection: "", context: .plain) == "changed")
    }

    @Test("Source mode passes every payload through exactly")
    func sourceModePassthrough() {
        let source = "# Source"
        let view = view(for: source, mode: .source)
        let payloads: [MarkdownPastePayload] = [
            .url("www.example.com"),
            .html("<p><strong>raw</strong></p>", fallback: ""),
            .text("a\tb\n1\t2"),
        ]
        for payload in payloads {
            let replacement = MarkdownSmartPaste.replacement(
                for: payload, selection: "", context: MarkdownSmartPaste.context(
                    for: NSRange(location: 0, length: 0), in: view.parsedDocument, mode: .source))
            switch payload {
            case .url(let value), .text(let value): #expect(replacement == value)
            case .html(let value, _): #expect(replacement == value)
            }
        }
    }
}
