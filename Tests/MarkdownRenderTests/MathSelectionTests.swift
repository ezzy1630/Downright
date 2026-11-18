import AppKit
import MarkdownCore
import Testing

@testable import MarkdownRender

@Test @MainActor func inlineMathStaysInSourceWhileSelecting() {
    let source = "# Title\n\nBefore $x$ after.\n"
    let storage = NSTextStorage(string: source)
    let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 500), storage: storage)
    view.update(document: MarkdownParser.parse(source), dirty: .wholesale)

    let formula = (source as NSString).range(of: "$x$")
    let latex = NSRange(location: formula.location + 1, length: 1)
    func showsAttachment() -> Bool {
        view.currentDisplayMap.substitutions(in: formula).contains {
            $0.replacement?.attribute(.attachment, at: 0, effectiveRange: nil) != nil
        }
    }
    func select(_ range: NSRange) {
        view.setSourceSelectedRanges([range])
        view.handleSelectionChanged(allowTypewriterScrolling: false)
    }
    #expect(showsAttachment())
    select(NSRange(location: latex.location, length: 0))
    #expect(!showsAttachment())
    select(latex)
    #expect(!showsAttachment())
    #expect(view.sourceSelectedRange == latex)
    select(NSRange(location: storage.length, length: 0))
    #expect(showsAttachment())
    #expect(storage.string == source)
}

@Test(arguments: ["", "# Title\n", "# Title\n\n"], ["$$f(x)$$", "$$\nf(x)\n$$"])
@MainActor func displayMathStaysInSourceWhileSelecting(prefix: String, formula: String) throws {
    let source = prefix + formula + "\n\nAfter\n"
    let storage = NSTextStorage(string: source)
    let style = StyleSheet(theme: .fallback, appearance: NSAppearance(named: .aqua) ?? .currentDrawing())
    let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 500),
                                storage: storage, styleSheet: style)
    view.mode = .live
    view.update(document: MarkdownParser.parse(source), dirty: .wholesale)
    view.prepareForDisplay()

    let layout = try #require(view.textLayoutManager)
    let manager = try #require(layout.textContentManager)
    let start = prefix.utf16.count
    let paragraphs = (formula as NSString).components(separatedBy: "\n")
    let lineOffsets = paragraphs.dropLast().reduce(into: [start]) { offsets, line in
        offsets.append(offsets[offsets.count - 1] + line.utf16.count + 1)
    }
    func fragment(at offset: Int) throws -> NSTextLayoutFragment {
        let index = view.currentDisplayMap.textKitOffset(forSource: offset)
        let location = try #require(manager.location(manager.documentRange.location, offsetBy: index))
        layout.ensureLayout(for: NSTextRange(location: location))
        return try #require(layout.textLayoutFragment(for: location))
    }
    func select(_ range: NSRange) {
        view.setSourceSelectedRanges([range])
        view.handleSelectionChanged(allowTypewriterScrolling: false)
    }

    let outside = (source as NSString).range(of: "After")
    let content = (source as NSString).range(of: "f(x)")
    select(NSRange(location: outside.location, length: 0))
    let rendered = try #require(try fragment(at: start) as? MathFragment)
    let frame = rendered.layoutFragmentFrame
    let origin = view.textContainerOrigin
    let renderedCenter = NSPoint(x: origin.x + frame.minX + rendered.contentWidth / 2,
                                 y: origin.y + frame.midY)
    #expect(view.renderedMathSourceOffset(at: renderedCenter) == content.location)

    select(NSRange(location: content.location, length: 0))
    for offset in lineOffsets {
        #expect(try fragment(at: offset) is ProseFragment, "Entering the formula reveals its whole source")
    }

    select(content)
    #expect(view.sourceSelectedRange == content)
    for offset in lineOffsets {
        #expect(try fragment(at: offset) is ProseFragment, "Selecting LaTeX keeps the source visible")
    }

    select(NSRange(location: outside.location, length: 0))
    #expect(try fragment(at: start) is MathFragment)
    #expect(storage.string == source)
}
