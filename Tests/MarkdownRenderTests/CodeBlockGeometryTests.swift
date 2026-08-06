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
                code.paragraphStyle?.headIndent ?? -1
            ))
            return true
        }
        return result
    }

    @Test("top-level band is flush with the column, right edge on the measure")
    func topLevelBandFlushesWithColumn() {
        let text = "# Top\n\n```swift\nfunc top() {}\n```\n"
        let container = Self.makeContainer(text)
        let fragments = Self.codeFragments(in: container)
        let measure = container.textView.styleSheet.measureWidth

        let roles: [CodeBlockFragment.Role] = [.openChrome, .body, .closeChrome]
        for role in roles {
            let fragment = fragments.first { $0.role == role }
            #expect(fragment != nil, "missing \(role) fragment")
            guard let fragment else { continue }
            // Left edge at the column (the fragment origin already carries the
            // codeInsetX indent), right edge on the measure.
            #expect(abs(fragment.band.minX) < 0.5, "band starts right of the column")
            #expect(abs(fragment.band.maxX - measure) < 0.5, "band overhangs the measure")
        }
    }

    @Test("nested code inside a list keeps its chrome and its list indent")
    func nestedCodeKeepsChromeAndListIndent() {
        let text = "- Item:\n\n  ```python\n  def nested():\n      pass\n  ```\n"
        let container = Self.makeContainer(text)
        let fragments = Self.codeFragments(in: container)
        let measure = container.textView.styleSheet.measureWidth

        // The opening fence must be chrome, not a plain paragraph rendering
        // the ``` line as literal text.
        let openFragments = fragments.filter { $0.role == .openChrome }
        #expect(!openFragments.isEmpty, "nested opening fence never became chrome")

        // Nested body lines earn the list content edge in their indent, not
        // the bare top-level code inset.
        let bodyIndent = fragments.first { $0.role == .body }?.headIndent ?? 0
        #expect(bodyIndent > RenderMetrics.codeInsetX + 8, "nested code lost its list indent")

        if let open = openFragments.first {
            // Band sits at the list content edge and still ends on the measure.
            #expect(open.band.minX > 1, "nested band should indent with its list")
            #expect(abs(open.band.maxX - measure) < 0.5, "nested band overhangs the measure")
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
        let measure = container.textView.styleSheet.measureWidth

        let open = fragments.first { $0.role == .openChrome }
        #expect(open != nil, "depth-2 opening fence never became chrome")
        guard let open else { return }

        // The depth-2 body paragraph's own content edge (structural indent +
        // marker column) is the authority the band must match.
        let bodyIndent = fragments.first { $0.role == .body }?.headIndent ?? 0
        #expect(abs(open.band.minX - (bodyIndent - RenderMetrics.codeInsetX)) < 0.5,
                "band \(open.band.minX) diverged from content edge \(bodyIndent - RenderMetrics.codeInsetX)")
        #expect(abs(open.band.maxX - measure) < 0.5, "depth-2 band overhangs the measure")
    }
}
