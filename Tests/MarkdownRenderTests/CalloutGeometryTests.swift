import AppKit
import Foundation
import MarkdownCore
import Testing

@testable import MarkdownRender

/// The callout band is drawn *under* real glyphs, so its left edge is the one
/// piece of geometry a reader sees fail immediately: get it wrong and the
/// coloured rule runs through the prose instead of beside it.
///
/// The defect this suite pins: `bandRect` used an absolute `x`, on the
/// assumption that a fragment draws in text-container coordinates.  It does
/// not.  At draw time TextKit hands every fragment `point == .zero` with the
/// context already translated to the fragment's origin — and that origin
/// carries the paragraph head indent, which for a callout *is* the icon
/// column.  The band therefore started exactly on the glyph edge, so body text
/// sat flush against the rule while the header — which adds `reservedInset` on
/// top of the band — was the only part correctly inset.
///
/// Every expectation below is written in the draw-time convention (`point` is
/// `.zero`, the origin is the glyph edge) because that is the space the bug
/// lived in.
@Suite("Callout geometry")
@MainActor
struct CalloutGeometryTests {

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

    private static func calloutFragments(in container: MarkdownContainerView) -> [CalloutFragment] {
        guard let layout = container.textView.textLayoutManager else { return [] }
        layout.ensureLayout(for: layout.documentRange)
        var result: [CalloutFragment] = []
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location,
                                            options: [.ensuresLayout]) { fragment in
            if let callout = fragment as? CalloutFragment { result.append(callout) }
            return true
        }
        return result
    }

    /// The whole point of the fix: the glyph edge must sit a full icon column
    /// inside the band, on *every* slice, so the header's title and the body's
    /// first character share a left edge.
    @Test("body text is inset from the rule by the icon column")
    func bodyTextClearsTheRule() {
        let text = "> [!NOTE] Heads up\n> Agents emit these constantly, so they get a real treatment.\n"
        let container = Self.makeContainer(text)
        let fragments = Self.calloutFragments(in: container)
        #expect(!fragments.isEmpty, "no callout fragments were built")

        let inset = RenderMetrics.calloutIconInsetX
        for fragment in fragments {
            let band = fragment.bandRect(at: .zero, reservedInset: inset)
            // The glyphs start at x == 0 in this space; the band must start a
            // full icon column to their left.
            #expect(abs(band.minX + inset) < 0.5,
                    "band starts at \(band.minX), expected \(-inset) — text would sit on the rule")
        }
    }

    /// A plain quote reserves the narrower column, and its band has to follow
    /// the same rule with the smaller inset rather than inheriting a callout's.
    @Test("a plain quote uses the quote inset, not the callout inset")
    func plainQuoteUsesItsOwnInset() {
        let text = "> Just a quote, no kind marker at all.\n"
        let container = Self.makeContainer(text)
        let fragments = Self.calloutFragments(in: container)
        #expect(!fragments.isEmpty, "no quote fragments were built")

        let inset = RenderMetrics.calloutInsetX
        for fragment in fragments {
            let band = fragment.bandRect(at: .zero, reservedInset: inset)
            #expect(abs(band.minX + inset) < 0.5,
                    "quote band starts at \(band.minX), expected \(-inset)")
        }
    }

    /// A nested list inside a callout indents its rows past the block's own
    /// head indent.  The band belongs to the block, so those rows must not step
    /// it right — that is what made the two ends of one callout disagree.
    @Test("a nested list inside a callout does not step the band right")
    func nestedContentKeepsOneBandEdge() {
        let text = """
        > [!TIP] With a list
        > Intro line.
        >
        > - first
        > - second

        """
        let container = Self.makeContainer(text)
        let fragments = Self.calloutFragments(in: container)
        #expect(fragments.count > 1, "expected several slices of one callout")

        // Each slice draws in its *own* origin's space, and a list row's origin
        // sits a marker column right of the header row's, so the raw `minX`
        // values are not comparable.  Adding the fragment origin back puts them
        // all in container coordinates, which is where "one band edge" means
        // something.
        let inset = RenderMetrics.calloutIconInsetX
        let edges = fragments.map {
            $0.bandRect(at: .zero, reservedInset: inset).minX + $0.layoutFragmentFrame.origin.x
        }
        guard let first = edges.first else { return }
        for edge in edges {
            #expect(abs(edge - first) < 0.5,
                    "band edges disagree across slices: \(edges)")
        }
    }

    /// `calloutKind` changes `indent(for:context:)` but was missing from the
    /// paragraph-style cache key, so a paragraph inside `> [!NOTE]` and one
    /// inside a bare `>` shared an entry and whichever decorated first locked
    /// the other into its indent.  Decorating the quote first is the order that
    /// exposed it.
    @Test("callout and blockquote paragraphs do not share a cached style")
    func calloutAndQuoteKeepSeparateIndents() {
        let sheet = MarkdownTextView.fallbackStyleSheet()
        let factory = BlockStyleFactory(styleSheet: sheet)
        let doc = MarkdownParser.parse("> plain quote\n\n> [!NOTE] kind\n> body\n")

        var quoteBody: CGFloat?
        var calloutBody: CGFloat?
        func walk(_ block: MDBlock, _ context: BlockContext) {
            var child = context
            switch block.content {
            case .list: child.listDepth += 1
            case .blockQuote: child.quoteDepth += 1; child.calloutKind = nil
            case .callout(let kind, _): child.quoteDepth += 1; child.calloutKind = kind
            case .listItem(let ordinal, _): child.ordinal = ordinal
            default: break
            }
            if case .paragraph = block.content, context.quoteDepth > 0 {
                let indent = factory.paragraphStyle(for: block, context: context).headIndent
                if context.calloutKind == nil { quoteBody = indent } else { calloutBody = indent }
            }
            for c in block.children { walk(c, child) }
        }
        walk(doc.root, .root)

        #expect(quoteBody != nil && calloutBody != nil, "did not reach both bodies")
        #expect(quoteBody != calloutBody,
                "quote and callout bodies both got \(quoteBody ?? -1) — the cache key aliases them")
        #expect(calloutBody == RenderMetrics.calloutIconInsetX,
                "callout body indent \(calloutBody ?? -1) is not the icon column")
    }
}
