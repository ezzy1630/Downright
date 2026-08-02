import Foundation
import MarkdownCore

// Which syntax markers are omitted from the display string, given a policy and
// a caret (§6.1a, §6.1b, §14).
//
// Pure functions over the parsed document — no view state, no storage — so the
// rules can be unit tested exactly as specified and the Quick Look extension
// gets identical behaviour without importing a view.

public enum MarkerPolicy {

    /// Ranges to omit, ascending and non-overlapping.
    ///
    /// Three rules, in order:
    ///
    ///  * **Block markers** (§6.1a).  `#`, `>`, `-`, `1.`, `- [ ]` are hidden
    ///    in Read and Live and rendered in the gutter instead.  They are never
    ///    revealed inline, not even under the caret — that is the whole point:
    ///    the block's style is identical whether or not it is active, so line
    ///    height and horizontal origin cannot move, which removes every source
    ///    of vertical jump.
    ///
    ///  * **Inline markers** (§6.1b).  Hidden per span.  When the caret
    ///    touches a span, only *that span's* markers come back — its siblings
    ///    on the same line stay collapsed.  Ancestors of the touched span are
    ///    revealed too, because the caret is inside them as well and showing
    ///    `**` while its enclosing `_` stays hidden reads as corruption.
    ///
    ///  * **Multiple carets** (§14).  Reveal at the primary caret only.  The
    ///    recommendation in §14 is followed literally; secondary carets get
    ///    thin markers drawn on hidden syntax by the view rather than a reveal,
    ///    so N carets never cause N reflows.
    public static func hiddenRanges(
        document: ParsedDocument,
        policy: DecorationPolicy,
        caret: Int?,
        selections: [NSRange]
    ) -> [NSRange] {
        guard policy.hidesBlockMarkers || policy.hidesInlineMarkers else { return [] }

        var out: [NSRange] = []
        out.reserveCapacity(256)

        // Selection is observation, not edit intent.  Dragging, double-click,
        // Shift-arrow, Look Up, speech, and copy all create non-empty
        // selections, so revealing syntax here would make the document move
        // under an ordinary selection gesture.  Only a real insertion caret
        // reveals inline markers.
        let revealAnchors: [NSRange]
        if policy.revealsAtCaret, let caret {
            revealAnchors = [NSRange(location: caret, length: 0)]
        } else {
            revealAnchors = []
        }

        document.root.walk { block in
            if policy.hidesBlockMarkers, blockMarkersAreHidden(block) {
                if let m = block.markerRange, m.length > 0 { out.append(m) }
                if let m = block.trailingMarkerRange, m.length > 0 { out.append(m) }
            }
            guard policy.hidesInlineMarkers, !block.inlines.isEmpty else { return }
            for span in block.inlines {
                collectInlineMarkers(span, anchors: revealAnchors, into: &out)
            }
        }
        return RangeSet.normalized(out)
    }

    /// Front matter and fenced code keep their delimiters in the source text:
    /// their fragments absorb those lines as chrome (the language chip, the
    /// metadata card's frame) rather than hiding characters, so the display
    /// string stays closer to the storage and selection still yields the fence.
    private static func blockMarkersAreHidden(_ block: MDBlock) -> Bool {
        switch block.content {
        case .codeBlock, .mermaid, .frontMatter, .mathBlock, .table, .thematicBreak:
            return false
        default:
            return true
        }
    }

    private static func collectInlineMarkers(
        _ span: InlineSpan,
        anchors: [NSRange],
        into out: inout [NSRange]
    ) {
        let revealed = span.kind.revealsMarkers && anchors.contains { touches($0, span.range) }
        if span.kind.revealsMarkers, !revealed {
            for m in span.markerRanges where m.length > 0 { out.append(m) }
        }
        // Descend regardless: a collapsed outer span can contain a revealed
        // inner one only when the caret is inside, and then the outer is
        // revealed too, so this stays consistent either way.
        for child in span.children {
            collectInlineMarkers(child, anchors: anchors, into: &out)
        }
    }

    private static func touches(_ anchor: NSRange, _ span: NSRange) -> Bool {
        if anchor.length == 0 { return span.touches(offset: anchor.location) }
        return anchor.location <= span.upperBound && span.location <= anchor.upperBound
    }

    /// Exactly the ranges `hiddenRanges` leaves out because of the caret — the
    /// complement of a caret-aware run against the fully collapsed one.
    ///
    /// The view keeps the fully collapsed set for the document and subtracts
    /// this on every caret move, because recomputing the whole hidden set per
    /// keystroke is O(document) and the budget is 8ms (§12).  Written as the
    /// mirror of `collectInlineMarkers` so the two cannot drift.
    public static func revealedMarkerRanges(
        document: ParsedDocument,
        policy: DecorationPolicy,
        caret: Int?,
        selections: [NSRange]
    ) -> [NSRange] {
        guard policy.hidesInlineMarkers, policy.revealsAtCaret else { return [] }

        // A lone insertion caret can identify its deepest block directly.
        // The general walk below remains for block-boundary carets, where two
        // adjacent blocks may both touch the anchor and retain inclusive
        // boundary behaviour.
        if let caret, selections.count <= 1,
           let block = document.root.block(at: caret),
           caret > block.range.location, caret < block.range.upperBound {
            var out: [NSRange] = []
            for span in block.inlines { collectRevealed(span, anchors: [NSRange(location: caret, length: 0)], into: &out) }
            return RangeSet.normalized(out)
        }

        guard let caret else { return [] }
        let anchors = [NSRange(location: caret, length: 0)]

        var out: [NSRange] = []
        document.root.walkPruning { block in
            guard anchors.contains(where: { touches($0, block.range) }) else { return false }
            for span in block.inlines { collectRevealed(span, anchors: anchors, into: &out) }
            return true
        }
        return RangeSet.normalized(out)
    }

    private static func collectRevealed(
        _ span: InlineSpan,
        anchors: [NSRange],
        into out: inout [NSRange]
    ) {
        if span.kind.revealsMarkers, anchors.contains(where: { touches($0, span.range) }) {
            for m in span.markerRanges where m.length > 0 { out.append(m) }
        }
        for child in span.children { collectRevealed(child, anchors: anchors, into: &out) }
    }

    /// The span whose markers a caret at `offset` reveals, if any.  The view
    /// uses it to compute the caret-anchored shift (§6.1c).
    public static func revealedSpan(document: ParsedDocument, caret: Int) -> InlineSpan? {
        guard let block = document.root.block(at: caret) else { return nil }
        for span in block.inlines {
            if let hit = deepestRevealing(span, caret: caret) { return hit }
        }
        return nil
    }

    private static func deepestRevealing(_ span: InlineSpan, caret: Int) -> InlineSpan? {
        guard span.range.touches(offset: caret) else { return nil }
        for child in span.children {
            if let hit = deepestRevealing(child, caret: caret) { return hit }
        }
        return span.kind.revealsMarkers ? span : nil
    }
}
