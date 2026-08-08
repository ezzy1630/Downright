import AppKit
import Foundation
import MarkdownCore
import Testing

@testable import MarkdownRender

/// The code band and its chrome are the most pixel-visible piece of the
/// renderer, so their geometry is locked down here.
///
/// Two past defects this suite pins:
///  * the band started `codeInsetX` right of the column — TextKit bakes the
///    paragraph head indent into the fragment origin, so drawing from
///    `point.x + indent` shifted the whole band (and its language chip) off
///    the text;
///  * a nested fenced block inside a list lost its chrome: the fence line's
///    paragraph starts at the source indentation *before* the block's range,
///    so the payload and marker probes at the paragraph start missed.
@Suite("Code block geometry")
@MainActor
struct CodeBlockGeometryTests {

    private static func makeContainer(_ text: String) -> MarkdownContainerView {
        let storage = NSTextStorage(string: text)
        let container = MarkdownContainerView(storage: storage)
        container.frame = NSRect(x: 0, y: 0, width: 1000, height: 900)
        container.layoutSubtreeIfNeeded()
        container.textView.mode = .read
        container.textView.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        container.textView.resizeToFitContent()
        return container
    }

    /// `headIndent` here is the block's *first-line* indent.  A wrapped code
    /// row hangs by a continuation indent, so `headIndent` proper is two
    /// columns deeper than the edge the band is measured from.
    private static func codeFragments(in container: MarkdownContainerView)
        -> [(source: NSRange, role: CodeBlockFragment.Role, band: CGRect, headIndent: CGFloat)] {
        guard let layout = container.textView.textLayoutManager else { return [] }
        layout.ensureLayout(for: layout.documentRange)
        var result: [(NSRange, CodeBlockFragment.Role, CGRect, CGFloat)] = []
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location,
                                            options: [.ensuresLayout]) { fragment in
            guard let code = fragment as? CodeBlockFragment else { return true }
            result.append((
                code.elementSourceRange,
                code.role,
                code.bandRect(at: fragment.layoutFragmentFrame.origin),
                code.paragraphStyle?.firstLineHeadIndent ?? -1
            ))
            return true
        }
        return result
    }

    /// Code is a full-bleed block: it shares its left edge with the prose above
    /// it and ends on the *column*, one bleed lane past the reading measure.
    /// At the measure alone a fenced block got barely fifty monospace columns.
    @Test("top-level band is flush with the column, right edge on the bleed lane")
    func topLevelBandFlushesWithColumn() {
        let text = "# Top\n\n```swift\nfunc top() {}\n```\n"
        let container = Self.makeContainer(text)
        let fragments = Self.codeFragments(in: container)
        let column = container.textView.columnWidth

        #expect(abs(column - (container.textView.styleSheet.measureWidth + RenderMetrics.codeBleed)) < 0.5,
                "the column should be the measure plus one bleed lane")

        let roles: [CodeBlockFragment.Role] = [.openChrome, .body, .closeChrome]
        for role in roles {
            let fragment = fragments.first { $0.role == role }
            #expect(fragment != nil, "missing \(role) fragment")
            guard let fragment else { continue }
            // Left edge at the column (the fragment origin already carries the
            // codeInsetX indent), right edge on the bleed lane.
            #expect(abs(fragment.band.minX) < 0.5, "band starts right of the column")
            #expect(abs(fragment.band.maxX - column) < 0.5, "band does not reach the bleed lane")
        }
    }

    /// Prose does *not* get the lane: a paragraph beside a code block still
    /// wraps at the reading measure, which is what the tail indent is for.
    @Test("prose keeps the reading measure while code takes the lane")
    func proseKeepsTheMeasure() {
        let text = "Some prose.\n\n```swift\nfunc top() {}\n```\n"
        let container = Self.makeContainer(text)
        let sheet = container.textView.styleSheet
        guard let storage = container.textView.textStorage else { return }
        let prose = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(abs((prose?.tailIndent ?? 0) + RenderMetrics.codeBleed) < 0.5,
                "prose tail indent \(prose?.tailIndent ?? 0) does not hold it to the measure")

        let codeStart = (text as NSString).range(of: "func top").location
        let code = storage.attribute(.paragraphStyle, at: codeStart, effectiveRange: nil) as? NSParagraphStyle
        #expect(abs((code?.tailIndent ?? 0) + RenderMetrics.codeInsetX) < 0.5,
                "code should stop one inset short of the column, not one bleed lane")
        #expect(sheet.measureWidth > 0)
    }

    /// The wrap that made this necessary: `.byCharWrapping` cut `ParsedDocument`
    /// into `Pars` / `edDocument`.  Word wrapping breaks at the gaps code
    /// already has, and the continuation indent keeps a wrapped row from
    /// impersonating a new line of source.
    @Test("code wraps on word boundaries and hangs its continuations")
    func codeWrapsOnWordBoundaries() {
        let text = "```swift\nfunc decorate(_ storage: NSTextStorage, document: ParsedDocument) {}\n```\n"
        let container = Self.makeContainer(text)
        guard let storage = container.textView.textStorage else { return }
        let codeStart = (text as NSString).range(of: "func decorate").location
        let style = storage.attribute(.paragraphStyle, at: codeStart, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.lineBreakMode == .byWordWrapping,
                "code still breaks mid-token")
        #expect((style?.headIndent ?? 0) > (style?.firstLineHeadIndent ?? 0),
                "wrapped code rows do not hang")
    }

    @Test("nested code inside a list keeps its chrome and its list indent")
    func nestedCodeKeepsChromeAndListIndent() {
        let text = "- Item:\n\n  ```python\n  def nested():\n      pass\n  ```\n"
        let container = Self.makeContainer(text)
        let fragments = Self.codeFragments(in: container)
        let column = container.textView.columnWidth

        // The opening fence must be chrome, not a plain paragraph rendering
        // the ``` line as literal text.
        let openFragments = fragments.filter { $0.role == .openChrome }
        #expect(!openFragments.isEmpty, "nested opening fence never became chrome")

        // Nested body lines earn the list content edge in their indent, not
        // the bare top-level code inset.
        let bodyIndent = fragments.first { $0.role == .body }?.headIndent ?? 0
        #expect(bodyIndent > RenderMetrics.codeInsetX + 8, "nested code lost its list indent")

        if let open = openFragments.first {
            // Band sits at the list content edge and still ends on the column.
            #expect(open.band.minX > 1, "nested band should indent with its list")
            #expect(abs(open.band.maxX - column) < 0.5, "nested band does not end on the column")
        }
    }

    @Test("nested code inside a blockquote keeps its chrome and its quote indent")
    func nestedCodeInBlockquoteKeepsChrome() {
        // The fence line's paragraph starts at the `> ` marker, not at the
        // block's range, so the probe must walk the quote prefix too.
        let text = "> ```swift\n> func quoted() {}\n> ```\n"
        let container = Self.makeContainer(text)
        let fragments = Self.codeFragments(in: container)

        let roles: [CodeBlockFragment.Role] = [.openChrome, .body, .closeChrome]
        for role in roles {
            let fragment = fragments.first { $0.role == role }
            #expect(fragment != nil, "missing \(role) fragment inside a blockquote")
        }
    }

    @Test("deeper list nesting keeps the band on the item's content edge")
    func deepNestingKeepsBandOnContentEdge() {
        let text = "- One\n  - Two\n\n    ```python\n    def deep():\n        pass\n    ```\n"
        let container = Self.makeContainer(text)
        let fragments = Self.codeFragments(in: container)
        let column = container.textView.columnWidth

        let open = fragments.first { $0.role == .openChrome }
        #expect(open != nil, "depth-2 opening fence never became chrome")
        guard let open else { return }

        // The depth-2 body paragraph's own content edge (structural indent +
        // marker column) is the authority the band must match.
        let bodyIndent = fragments.first { $0.role == .body }?.headIndent ?? 0
        #expect(abs(open.band.minX - (bodyIndent - RenderMetrics.codeInsetX)) < 0.5,
                "band \(open.band.minX) diverged from content edge \(bodyIndent - RenderMetrics.codeInsetX)")
        #expect(abs(open.band.maxX - column) < 0.5, "depth-2 band does not end on the column")
    }

    /// The stray shading blocks: the closing fence used to claim a surface
    /// `copyControlOverhang` taller than its own band and fill it, so a band
    /// that is exactly `codeInsetY` high painted a tinted rectangle reaching
    /// past the block's bottom edge.  TextKit 2 composites each fragment as an
    /// independent surface, so the neighbour under that overhang did not always
    /// repaint over it.  The band must stay inside the fragment's own frame.
    @Test("the closing band never overhangs its own frame vertically")
    func closingBandStaysInsideItsFrame() {
        let text = "# Top\n\n```swift\nfunc a() {}\n```\n\nAfter.\n"
        let container = Self.makeContainer(text)
        let fragments = Self.codeFragments(in: container)

        guard let close = fragments.first(where: { $0.role == .closeChrome }) else {
            Issue.record("missing closeChrome fragment")
            return
        }
        // The band is exactly the close-chrome frame: `codeInsetY` tall, with no
        // reach above the last code line or below the block's own edge.
        #expect(abs(close.band.height - RenderMetrics.codeInsetY) < 0.5,
                "closing band height \\(close.band.height) is not codeInsetY — it overhangs its frame")
    }

    /// Header and footer carry the rounded corners on their *outer* edges only;
    /// the edges they share with body lines are square, so adjacent fragments
    /// butt flush instead of double-painting a seam.
    @Test("header and footer bands are exactly their own chrome heights")
    func chromeBandsAreFlushWithTheirFrames() {
        let text = "# Top\n\n```swift\nfunc a() {}\n```\n"
        let container = Self.makeContainer(text)
        let fragments = Self.codeFragments(in: container)

        let open = fragments.first { $0.role == .openChrome }
        let close = fragments.first { $0.role == .closeChrome }
        #expect(open != nil && close != nil)
        if let open {
            #expect(abs(open.band.height - RenderMetrics.codeHeaderHeight) < 0.5,
                    "header band should be exactly codeHeaderHeight, no downward overdraw")
        }
        if let close {
            #expect(abs(close.band.height - RenderMetrics.codeInsetY) < 0.5,
                    "footer band should be exactly codeInsetY, no upward overdraw")
        }
    }
}
