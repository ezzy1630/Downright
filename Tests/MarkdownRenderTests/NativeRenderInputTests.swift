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
}
