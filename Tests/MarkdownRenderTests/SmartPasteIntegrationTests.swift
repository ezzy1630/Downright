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

    @Test("Downright Markdown flavour wins on an internal round trip")
    func privateMarkdownPriority() {
        let pasteboard = isolatedPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("**lossless**", forType: .downrightMarkdown)
        pasteboard.setString("https://example.com", forType: .URL)
        pasteboard.setString("lossless", forType: .string)

        #expect(MarkdownSmartPaste.payload(from: pasteboard) == .markdown("**lossless**"))
    }

    @Test("standard copy exposes visible text and keeps Markdown as an alternate")
    func visibleCopyWithMarkdownAlternate() throws {
        let source = "Before **bold** after"
        let view = view(for: source)
        let selection = (source as NSString).range(of: "**bold**")
        view.setSourceSelectedRanges([selection])
        let pasteboard = isolatedPasteboard()

        #expect(view.writeSelection(to: pasteboard, types: []))
        #expect(pasteboard.string(forType: .string) == "bold")
        #expect(pasteboard.string(forType: .downrightMarkdown) == "**bold**")
        #expect(pasteboard.data(forType: .rtf) != nil)
    }

    @Test("scoped and full Source Focus are explicit and reversible")
    func sourceFocusLifecycle() {
        let source = "First **line**.\nSecond line.\n"
        let view = view(for: source)
        let selection = (source as NSString).range(of: "line")

        view.focusSource(in: selection)
        let expected = (source as NSString).paragraphRange(for: selection)
        #expect(view.sourceFocus == .scoped(expected))
        #expect(view.sourceSelectedRange == selection)
        #expect(view.textStorage?.attribute(.drSourceFocus, at: selection.location, effectiveRange: nil) != nil)
        #expect(view.textStorage?.attribute(.drHidden, at: selection.location, effectiveRange: nil) == nil)
        let sourceColor = view.textStorage?.attribute(
            .foregroundColor,
            at: selection.location,
            effectiveRange: nil
        ) as? NSColor
        #expect((sourceColor?.alphaComponent ?? 0) > 0)

        view.clearSourceFocus()
        #expect(view.sourceFocus == .none)
        #expect(view.mode == .live)

        view.focusEntireSource()
        #expect(view.sourceFocus == .document)
        #expect(view.mode == .source)
        view.clearSourceFocus()
        #expect(view.sourceFocus == .none)
        #expect(view.mode == .live)
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

    @Test("Safari public.html keeps rich structure ahead of flattened fallback")
    func safariHTMLRoundTrip() {
        let pasteboard = isolatedPasteboard()
        pasteboard.clearContents()
        let html = """
        <!DOCTYPE html><html><head><style>body { color: red }</style></head><body><!--StartFragment-->
        <div><h2>Heading</h2><p>Intro <strong>bold</strong> and <a href="https://example.com">link</a>.</p>
        <ul><li>first<ul><li>nested <code>code</code></li></ul></li><li>second</li></ul>
        <table><tbody><tr><th>Name</th><th>Count</th></tr><tr><td>Ada</td><td>1</td></tr></tbody></table>
        <script>window.evil = true</script></div><!--EndFragment--></body></html>
        """
        pasteboard.setString(html, forType: .html)
        // Safari advertises several rich aliases and a flattened public.text
        // fallback. Normal Paste must consume public.html, not the fallback.
        pasteboard.setString("Heading Intro bold and link. first nested code second Name Count Ada 1", forType: .string)
        pasteboard.setData(Data([0x00, 0x01]), forType: .rtf)
        pasteboard.setData(Data([0x02, 0x03]), forType: .appleWebArchive)

        let payload = MarkdownSmartPaste.payload(from: pasteboard)
        guard let payload else {
            Issue.record("Safari-style clipboard did not expose a payload")
            return
        }
        let replacement = MarkdownSmartPaste.replacement(
            for: payload, selection: "", context: .markdown)
        #expect(replacement.contains("## Heading"))
        #expect(replacement.contains("**bold**"))
        #expect(replacement.contains("[link](https://example.com)"))
        #expect(replacement.contains("- first\n  - nested `code`\n- second"))
        #expect(replacement.contains("| Name"))
        #expect(replacement.contains("| Ada"))
        #expect(!replacement.contains("window.evil"))
        #expect(!replacement.contains("Heading Intro bold and link. first nested code"))
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

    @Test("document mode stays editable across repeated typing and deletion")
    func repeatedDocumentEditing() {
        let view = view(for: "# Title\n\nBody with **bold** text.\n")
        #expect(view.isEditable)

        let bodyEnd = (view.textStorage!.string as NSString).range(of: "Body").upperBound
        view.setSourceSelectedRanges([NSRange(location: bodyEnd, length: 0)])
        for character in " grows" {
            #expect(view.performSourceEdit(
                range: view.sourceSelectedRange,
                replacement: String(character)))
        }
        #expect(view.textStorage?.string == "# Title\n\nBody grows with **bold** text.\n")
        #expect(view.sourceSelectedRange == NSRange(location: bodyEnd + 6, length: 0))

        view.deleteBackward(nil)
        #expect(view.textStorage?.string == "# Title\n\nBody grow with **bold** text.\n")
        #expect(view.sourceSelectedRange == NSRange(location: bodyEnd + 5, length: 0))
    }

    @Test("AppKit selection, Delete, and typing mutate the rendered document")
    func appKitEditingEntryPoints() {
        let source = "# Title\n\nBody with **bold** text.\n"
        let view = view(for: source)
        let bold = (source as NSString).range(of: "bold")
        let displayedBold = view.currentDisplayMap.textKitRange(forSource: bold)

        // Use NSTextView's public selection path, as a mouse drag does. This
        // catches source/display mapping bugs that `performSourceEdit` cannot.
        view.setSelectedRange(displayedBold)
        #expect(view.sourceSelectedRange == bold)
        view.deleteBackward(nil)
        #expect(view.textStorage?.string == "# Title\n\nBody with **** text.\n")

        let insertion = (view.textStorage!.string as NSString).range(of: "Body").upperBound
        view.setSourceSelectedRanges([NSRange(location: insertion, length: 0)])
        view.insertText(" grows", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.textStorage?.string == "# Title\n\nBody grows with **** text.\n")
        #expect(view.sourceSelectedRange == NSRange(location: insertion + 6, length: 0))
    }

    @Test("an edit keeps unaffected paragraphs rendered until async parse commits")
    func transientEditProjection() throws {
        let source = "# Title\n\nBody with **bold** text.\n\nTail with _emphasis_.\n"
        let view = view(for: source)
        view.zoomLevel = .skeleton
        let body = (source as NSString).range(of: "Body with **bold** text.\n")
        let tailMarker = (source as NSString).range(of: "_emphasis_").location

        #expect(!view.currentDisplayMap.hiddenRanges.isEmpty)
        #expect(view.performSourceEdit(
            range: NSRange(location: body.location + 4, length: 0),
            replacement: " edited"
        ))
        #expect(view.zoomLevel == .everything)

        let projected = view.currentDisplayMap.hiddenRanges
        let editedParagraph = view.paragraphIndex.paragraphRange(containing: body.location)
        #expect(projected.contains { NSIntersectionRange($0, editedParagraph).length > 0 })
        #expect(projected.contains { $0.location >= tailMarker + 7 })
        #expect(view.currentDisplayMap.paragraphs.length == view.textStorage?.length)
    }

    @Test("typing in a heading never flashes its source marker")
    func transientHeadingEditKeepsMarkerHidden() throws {
        let source = "# Title\n\nBody\n"
        let view = view(for: source)
        let marker = NSRange(location: 0, length: 2)

        #expect(view.currentDisplayMap.hiddenRanges.contains(marker))
        #expect(view.performSourceEdit(
            range: NSRange(location: (source as NSString).range(of: "Title").upperBound, length: 0),
            replacement: " grows"
        ))

        #expect(view.currentDisplayMap.hiddenRanges.contains(marker))
        #expect(view.textStorage?.attribute(.drHidden, at: 0, effectiveRange: nil) != nil)
    }

    @Test("an edit keeps unrelated hard-wrapped blocks reflowed until async parse commits")
    func transientEditProjectionKeepsHardWrapReflow() throws {
        let source = """
        # Title

        First prose line wraps in the source
        but remains one rendered paragraph.

        Second prose line also wraps in the source
        and must not flash back to physical lines.
        """
        let view = view(for: source)
        let oldBreak = (source as NSString).range(of: "source\nbut")
        let laterBreak = (source as NSString).range(of: "source\nand")

        #expect(view.currentDisplayMap.substitutions.contains {
            $0.isHardWrapReflow && $0.sourceRange.location == oldBreak.location + 6
        })
        #expect(view.performSourceEdit(
            range: NSRange(location: (source as NSString).range(of: "Title").upperBound, length: 0),
            replacement: " grows"
        ))

        let delta = (" grows" as NSString).length
        let projectedBreaks = view.currentDisplayMap.substitutions
            .filter(\.isHardWrapReflow)
            .map(\.sourceRange.location)
        #expect(projectedBreaks.contains(oldBreak.location + 6 + delta))
        #expect(projectedBreaks.contains(laterBreak.location + 6 + delta))
    }

    @Test("ordinary typing keeps its own hard-wrapped block reflowed")
    func transientEditProjectionKeepsTouchedHardWrapBlock() throws {
        let source = """
        # Title

        First prose line wraps in the source
        but remains one rendered paragraph.

        Second prose line also wraps in the source
        and stays rendered while the first changes.
        """
        let view = view(for: source)
        let firstBreak = (source as NSString).range(of: "source\nbut")
        let secondBreak = (source as NSString).range(of: "source\nand")
        let edit = (source as NSString).range(of: "First")

        #expect(view.performSourceEdit(
            range: NSRange(location: edit.upperBound, length: 0),
            replacement: " edited"
        ))

        let delta = (" edited" as NSString).length
        let projectedBreaks = view.currentDisplayMap.substitutions
            .filter(\.isHardWrapReflow)
            .map(\.sourceRange.location)
        #expect(projectedBreaks.contains(firstBreak.location + 6 + delta))
        #expect(projectedBreaks.contains(secondBreak.location + 6 + delta))
    }

    @Test("a newline edit invalidates its touched hard-wrapped block")
    func transientStructuralEditDropsTouchedHardWrapBlock() throws {
        let source = """
        # Title

        First prose line wraps in the source
        but remains one rendered paragraph.

        Second prose line also wraps in the source
        and stays rendered while the first changes.
        """
        let view = view(for: source)
        let firstBreak = (source as NSString).range(of: "source\nbut")
        let secondBreak = (source as NSString).range(of: "source\nand")
        let edit = (source as NSString).range(of: "First")

        #expect(view.performSourceEdit(
            range: NSRange(location: edit.upperBound, length: 0),
            replacement: "\n"
        ))

        let projectedBreaks = view.currentDisplayMap.substitutions
            .filter(\.isHardWrapReflow)
            .map(\.sourceRange.location)
        #expect(!projectedBreaks.contains(firstBreak.location + 6))
        #expect(projectedBreaks.contains(secondBreak.location + 7))
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
            case .markdown(let value): #expect(replacement == value)
            case .url(let value), .text(let value): #expect(replacement == value)
            case .html(let value, _): #expect(replacement == value)
            case .richText(let value), .file(let value): #expect(replacement == value)
            case .image: #expect(replacement == "Pasted image")
            }
        }
    }
}
