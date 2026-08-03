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

        if policy.hidesBlockMarkers {
            // Reference and footnote definitions are document metadata, not
            // body prose. Their resolved uses remain visible at the point of
            // reading; the raw definitions belong only in Source Focus.
            // Display substitutions cannot cross a physical paragraph
            // boundary, so split multi-line footnotes before publishing the
            // policy instead of asking DisplayMap to reject them.
            let definitions = document.linkReferences.values.map(\.range)
                + document.footnotes.values.map(\.range)
            out.append(contentsOf: definitions.flatMap {
                paragraphLocalRanges(in: $0, document: document)
            })
        }

        // Selection is observation, not edit intent.  Dragging, double-click,
        // Shift-arrow, Look Up, speech, and copy all create non-empty
        // selections, so revealing syntax here would make the document move
        // under an ordinary selection gesture.  Only a real insertion caret
        // reveals inline markers.
        let revealAnchors = anchors(policy: policy, caret: caret, selections: selections)

        document.root.walk { block in
            if policy.hidesBlockMarkers, blockMarkersAreHidden(block) {
                if let m = block.markerRange, m.length > 0 { out.append(m) }
                if let m = block.trailingMarkerRange, m.length > 0 { out.append(m) }
                switch block.content {
                case .blockQuote, .callout:
                    // swift-markdown exposes the quote as one container and
                    // does not give every continuation line its own marker
                    // range. Hide each physical `>` prefix explicitly; if we
                    // hide only the opening line, the remaining source marks
                    // leak into rendered prose as repeated black chevrons.
                    out.append(contentsOf: quotePrefixRanges(in: block, document: document))
                default:
                    break
                }
            }
            guard policy.hidesInlineMarkers, !block.inlines.isEmpty else { return }
            for span in block.inlines {
                collectInlineMarkers(span, anchors: revealAnchors, into: &out)
            }
        }
        return RangeSet.normalized(out)
    }

    private static func quotePrefixRanges(
        in block: MDBlock,
        document: ParsedDocument
    ) -> [NSRange] {
        guard block.range.length > 0 else { return [] }
        let text = document.text as NSString
        var result: [NSRange] = []

        for (index, lineStart) in document.lineStarts.enumerated()
        where lineStart < block.range.upperBound {
            let lineEnd = index + 1 < document.lineStarts.count
                ? document.lineStarts[index + 1]
                : document.length
            guard lineEnd > block.range.location, lineStart >= block.range.location else { continue }

            var cursor = lineStart
            while cursor < lineEnd {
                let character = text.character(at: cursor)
                guard character == 0x20 || character == 0x09 else { break }
                cursor += 1
            }
            let markerStart = cursor
            var sawQuote = false
            while cursor < lineEnd, text.character(at: cursor) == 0x3E {
                sawQuote = true
                cursor += 1
                if cursor < lineEnd, text.character(at: cursor) == 0x20 { cursor += 1 }
                while cursor < lineEnd, text.character(at: cursor) == 0x09 { cursor += 1 }
            }
            if sawQuote, cursor > markerStart {
                result.append(NSRange(location: markerStart, length: cursor - markerStart))
            }
        }
        return result
    }

    private static func paragraphLocalRanges(
        in sourceRange: NSRange,
        document: ParsedDocument
    ) -> [NSRange] {
        guard sourceRange.length > 0 else { return [] }
        var result: [NSRange] = []
        for index in document.lineStarts.indices {
            let line = document.range(ofLine: index + 1)
            guard line.location < sourceRange.upperBound else { break }
            let intersection = NSIntersectionRange(line, sourceRange)
            if intersection.length > 0 { result.append(intersection) }
        }
        return result
    }

    /// Front matter and fenced code keep their delimiters in the source text:
    /// their fragments absorb those lines as chrome (the language chip, the
    /// metadata card's frame) rather than hiding characters, so the display
    /// string stays closer to the storage and selection still yields the fence.
    private static func blockMarkersAreHidden(_ block: MDBlock) -> Bool {
        switch block.content {
        case .codeBlock, .mermaid, .frontMatter, .mathBlock, .table, .thematicBreak:
            return false
        case .callout:
            // Callout syntax is block chrome too.  The parser keeps the exact
            // `> [!KIND]` range on the callout node, so hiding it here cannot
            // change any source coordinate or the child ranges below it.
            return true
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
        let anchors = anchors(policy: policy, caret: caret, selections: selections)
        guard !anchors.isEmpty else { return [] }

        // A lone insertion caret can identify its deepest block directly.
        // The general walk below remains for block-boundary carets, where two
        // adjacent blocks may both touch the anchor and retain inclusive
        // boundary behaviour.
        if anchors.count == 1,
           let anchor = anchors.first,
           let block = document.root.block(at: anchor.location),
           anchor.location > block.range.location, anchor.location < block.range.upperBound {
            var out: [NSRange] = []
            for span in block.inlines { collectRevealed(span, anchors: anchors, into: &out) }
            return RangeSet.normalized(out)
        }

        var out: [NSRange] = []
        document.root.walkPruning { block in
            guard anchors.contains(where: { touches($0, block.range) }) else { return false }
            for span in block.inlines { collectRevealed(span, anchors: anchors, into: &out) }
            return true
        }
        return RangeSet.normalized(out)
    }

    private static func anchors(
        policy: DecorationPolicy, caret: Int?, selections: [NSRange]
    ) -> [NSRange] {
        guard policy.revealsAtCaret else { return [] }
        if policy.revealsAtAllCursors {
            var out = selections.filter { $0.length == 0 }
            if let caret, !out.contains(where: { $0.location == caret }) {
                out.append(NSRange(location: caret, length: 0))
            }
            return out
        }
        return caret.map { [NSRange(location: $0, length: 0)] } ?? []
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
