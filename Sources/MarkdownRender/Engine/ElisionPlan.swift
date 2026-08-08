import Foundation
import MarkdownCore

// Structural zoom (§5.2) × heading folding (§7.1) × find (§7.2, §9.4) ×
// hidden markers (§6.1) — the four-way interaction §14 says to specify before
// implementing.  This file *is* that specification, and it is the only place
// the four are combined.
//
// ────────────────────────────────────────────────────────────────────────
// THE RULE
//
//  1. Elision and marker hiding are orthogonal mechanisms over disjoint
//     ranges.  Markers are omitted from the display string (`DisplayMap`);
//     elided ranges keep every character in the display string and are
//     collapsed to zero height by `ElidedFragment`.  A range is therefore
//     never both, and no conversion in `DisplayMap` has to know about zoom or
//     folding.  This is what stops the interaction from multiplying.
//
//  2. The elision candidates are the union of the zoom plan's elided ranges
//     and the section range (heading line excluded) of every folded heading.
//
//  3. **A search hit, the caret, or a selection inside a candidate forces
//     that whole candidate visible.**  Whole, never partially: revealing half
//     a folded section reads as corruption, and "expand the collapsed section
//     containing the match" is exactly what §7.2 and §9.4 ask for.
//
//  4. Rule 3 is a *render-time* override, not a state change: the zoom level
//     and the fold set are untouched, so clearing the search restores the
//     previous shape without the app having to remember anything.  The one
//     exception is explicit and lives in the view — setting `searchHits`
//     unfolds headings whose sections contain a hit, because a fold is a user
//     gesture the user expects to see undone.
// ────────────────────────────────────────────────────────────────────────

public struct ElisionPlan: Sendable {
    /// Ranges collapsed to zero height, ascending and non-overlapping.
    public var elidedRanges: [NSRange]
    /// Candidates that rule 3 forced back into view, for the "N paragraphs
    /// hidden" affordance and for tests.
    public var forcedVisibleRanges: [NSRange]

    public static let none = ElisionPlan(elidedRanges: [], forcedVisibleRanges: [])

    public init(elidedRanges: [NSRange], forcedVisibleRanges: [NSRange]) {
        self.elidedRanges = elidedRanges
        self.forcedVisibleRanges = forcedVisibleRanges
    }

    public var isIdentity: Bool { elidedRanges.isEmpty }

    public func isElided(_ offset: Int) -> Bool { RangeSet.covers(elidedRanges, offset) }

    public func range(containing offset: Int) -> NSRange? {
        elidedRanges.first { $0.contains(offset: offset) }
    }

    // MARK: - Construction

    public static func make(
        document: ParsedDocument,
        zoom: ZoomLevel,
        foldedHeadingSlugs: Set<String>,
        searchHits: [NSRange],
        caret: Int?,
        selections: [NSRange]
    ) -> ElisionPlan {
        var candidates: [NSRange] = []

        if zoom != .everything {
            candidates.append(contentsOf: StructuralZoom.plan(document, level: zoom).elidedRanges)
        }
        if !foldedHeadingSlugs.isEmpty {
            for heading in document.headings where foldedHeadingSlugs.contains(heading.slug) {
                let body = bodyRange(of: heading)
                if body.length > 0 { candidates.append(body) }
            }
        }
        candidates = RangeSet.normalized(candidates)
        guard !candidates.isEmpty else { return .none }

        var probes = searchHits
        if let caret { probes.append(NSRange(location: caret, length: 0)) }
        probes.append(contentsOf: selections)
        guard !probes.isEmpty else {
            return ElisionPlan(elidedRanges: candidates, forcedVisibleRanges: [])
        }

        var kept: [NSRange] = []
        var forced: [NSRange] = []
        for candidate in candidates {
            if probes.contains(where: { probeTouches($0, candidate) }) { forced.append(candidate) }
            else { kept.append(candidate) }
        }
        return ElisionPlan(elidedRanges: kept, forcedVisibleRanges: forced)
    }

    /// A folded heading hides its body, never its own line — otherwise there is
    /// nothing left to click to unfold (§7.1).
    public static func bodyRange(of heading: HeadingNode) -> NSRange {
        let start = Swift.max(heading.range.upperBound, heading.sectionRange.location)
        let end = heading.sectionRange.upperBound
        return NSRange(location: start, length: Swift.max(0, end - start))
    }

    private static func probeTouches(_ probe: NSRange, _ candidate: NSRange) -> Bool {
        if probe.length == 0 { return candidate.contains(offset: probe.location) }
        return probe.location < candidate.upperBound && candidate.location < probe.upperBound
    }
}
