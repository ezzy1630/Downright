import AppKit
import MarkdownCore
import NativeUITestSupport
import Testing

@testable import MarkdownRender

@Suite(.serialized)
@MainActor
struct NativeRenderInputTests {
    @Test func pointerShowsAndClearsLinkTooltip() throws {
        _ = NSApplication.shared
        let source = "Before [Link](https://example.com/path) after.\n"
        let container = MarkdownContainerView(storage: NSTextStorage(string: source))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.resignKey(); window.close() }
        window.contentView = container
        let view = container.textView
        view.mode = .live
        view.update(document: MarkdownParser.parse(source), dirty: .wholesale)
        let input = WindowInput(window)
        view.resizeToFitContent()
        view.prepareForDisplay()
        try #require(!window.isKeyWindow && !NSApp.isActive)

        func move(inside text: String) throws {
            let range = (source as NSString).range(of: text)
            let start = try #require(view.rect(forOffset: range.location))
            let end = try #require(view.rect(forOffset: range.upperBound))
            let point = NSPoint(x: (start.minX + end.minX) / 2, y: start.midY)
            try input.move(to: view.convert(point, to: nil))
        }

        try move(inside: "Link")
        #expect(view.toolTip == "https://example.com/path")
        try move(inside: "after")
        #expect(view.toolTip == nil)
        #expect(view.textStorage?.string == source)
    }

    /// Issue #68 made a caret inside a block object reveal it immediately. A
    /// plain click on an image still opens it without swapping it to source;
    /// Option-click is the edit gesture and reveals the Markdown.
    @Test func imageClickOpensWithoutRevealAndOptionClickEdits() throws {
        _ = NSApplication.shared
        let source = "Before.\n\n![Pixel](pixel.png)\n\nAfter.\n"
        let image = (source as NSString).range(of: "![Pixel](pixel.png)")
        let container = MarkdownContainerView(storage: NSTextStorage(string: source))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.resignKey(); window.close() }
        window.contentView = container
        let view = container.textView
        let host = ImageActivationRecorder()
        view.markdownDelegate = host
        view.mode = .live
        view.update(document: MarkdownParser.parse(source), dirty: .wholesale)
        let input = WindowInput(window)
        view.resizeToFitContent()
        view.prepareForDisplay()
        try #require(!window.isKeyWindow && !NSApp.isActive)
        try #require(window.makeFirstResponder(view))
        try #require(try layoutFragment(at: image.location, in: view) is ImageFragment, "The image must start rendered")

        // Inside the invisible source glyphs at the image's left edge.
        let glyph = try #require(view.rect(forOffset: image.location + 4))
        let point = view.convert(NSPoint(x: glyph.minX + 1, y: glyph.midY), to: nil)

        try input.click(at: point)
        #expect(host.activations == ["pixel.png"], "A plain click should open the image once")
        #expect(view.sourceSelectedRange == NSRange(location: image.location, length: 0),
                "A plain click left the caret at \(view.sourceSelectedRange), inside the image source")
        let afterClick = try layoutFragment(at: image.location, in: view)
        #expect(afterClick is ImageFragment, "A plain click swapped the image to source: \(type(of: afterClick))")

        try input.click(at: point, modifiers: [.option])
        let caret = view.sourceSelectedRange
        #expect(caret.length == 0 && caret.location > image.location && caret.location < image.upperBound,
                "Option-click put the caret at \(caret), not inside the image source")
        let afterOptionClick = try layoutFragment(at: image.location, in: view)
        #expect(afterOptionClick is ProseFragment,
                "Option-click inside the image did not reveal its Markdown: \(type(of: afterOptionClick))")
        #expect(host.activations == ["pixel.png"], "Option-click should not open the image")
        #expect(view.textStorage?.string == source)
    }

    private func layoutFragment(at sourceOffset: Int, in view: MarkdownTextView) throws -> NSTextLayoutFragment {
        let layout = try #require(view.textLayoutManager)
        let storage = try #require(layout.textContentManager)
        let offset = view.currentDisplayMap.textKitOffset(forSource: sourceOffset)
        let location = try #require(storage.location(storage.documentRange.location, offsetBy: offset))
        layout.ensureLayout(for: NSTextRange(location: location))
        return try #require(layout.textLayoutFragment(for: location))
    }
}

@MainActor
private final class ImageActivationRecorder: MarkdownTextViewDelegate {
    var activations: [String] = []
    func markdownTextView(_ view: MarkdownTextView, didActivateImage source: String, at range: NSRange) {
        activations.append(source)
    }
}
