// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
import AppKit
import MarkdownCore

/// Source-preserving maps for a rendered (non-source) presentation.
///
/// Extracted from the text view so image substitutions use the same mapping
/// and source-preservation rules as math and hidden syntax.
struct BaseDisplayMaps {
    var hidden: [NSRange]
    var hardWrapRanges: [NSRange]
    var hardWrapSubstitutions: [DisplaySubstitution]
    var logical: DisplayMap
}

enum PresentationMaps {
    /// The logical display map for `document` before any caret reveal:
    /// hidden markers, inline math, footnote references, safe-HTML line breaks
    /// and hard-wrap reflow.  `excludedRange` is a scoped source focus, shown raw.
    static func base(
        document: ParsedDocument,
        engine: DecorationEngine,
        styleSheet: StyleSheet,
        policy: DecorationPolicy,
        excluding excludedRange: NSRange?,
        reflowHardWrappedParagraphs: Bool,
        text source: NSString,
        paragraphIndex: ParagraphIndex,
        inlineImages: InlineImageContext? = nil,
        joinsHTMLParagraphs: Bool = false
    ) -> BaseDisplayMaps {
        var hidden = engine.hiddenRanges(document: document, caret: nil, selections: [])
        if let focus = excludedRange {
            hidden.removeAll { NSIntersectionRange($0, focus).length > 0 }
        }
        let lineBreakSubstitutions = policy.rendersFragments
            ? Self.safeHTMLLineBreakSubstitutions(in: document, excluding: excludedRange)
            : []
        if !lineBreakSubstitutions.isEmpty {
            hidden = Self.removingOverlaps(
                hidden, with: lineBreakSubstitutions.map(\.sourceRange)
            )
        }

        let mathRanges = policy.rendersFragments
            ? InlineMathDisplay.ranges(in: document).filter { range in
                guard let focus = excludedRange else { return true }
                return NSIntersectionRange(range, focus).length == 0
            }
            : []
        // The math replacement owns its delimiters and content as one visual
        // object. Keeping the marker substitutions too would overlap the
        // object range, causing DisplayMap to reject one of the entries.
        hidden = Self.removingOverlaps(hidden, with: mathRanges)
        let mathSubstitutions = policy.rendersFragments
            ? InlineMathDisplay.substitutions(
                in: document, styleSheet: styleSheet, excluding: excludedRange)
            : []

        // Inline images, like math, own
        // the whole image syntax, so markers inside it are not hidden too.
        let inlineImageItems: [InlineImageDisplay.Item]
        if policy.rendersFragments, let inlineImages {
            inlineImageItems = InlineImageDisplay.items(
                in: document, includesRemoteHTML: inlineImages.remoteImageLoader != nil,
                joinsHTMLParagraphs: joinsHTMLParagraphs
            ).filter { item in
                guard let focus = excludedRange else { return true }
                return NSIntersectionRange(item.range, focus).length == 0
            }
        } else {
            inlineImageItems = []
        }
        inlineImages?.items = inlineImageItems
        hidden = Self.removingOverlaps(hidden, with: inlineImageItems.map(\.range))
        let inlineImageSubstitutions = inlineImages.map {
            InlineImageDisplay.substitutions(for: inlineImageItems, context: $0, styleSheet: styleSheet)
        } ?? []

        let footnoteReferences = policy.hidesInlineMarkers
            ? FootnoteReferenceDisplay.references(in: document).filter { reference in
                guard let focus = excludedRange else { return true }
                return NSIntersectionRange(reference.range, focus).length == 0
            }
            : []
        hidden = Self.removingOverlaps(hidden, with: footnoteReferences.map(\.range))
        let footnoteSubstitutions = policy.hidesInlineMarkers
            ? FootnoteReferenceDisplay.substitutions(
                in: document, styleSheet: styleSheet, excluding: excludedRange
            )
            : []

        let plan: HardWrapReflow.Plan
        let reflowsMarkdown = reflowHardWrappedParagraphs
            && Self.containsHardWrappedParagraph(in: document, text: source)
        // Safe HTML rows join for reading without changing physical source lines.
        let joinsHTML = joinsHTMLParagraphs && policy.rendersFragments
            && Self.containsMultilineHTMLParagraph(in: document, text: source)
        if reflowsMarkdown || joinsHTML {
            plan = HardWrapReflow.plan(
                document: document,
                text: source,
                hiddenRanges: hidden,
                enabled: reflowsMarkdown,
                joinsHTMLParagraphs: joinsHTML
            )
        } else {
            // Most generated large documents use one physical line per
            // paragraph. HardWrapReflow still walks every character in every
            // paragraph in that case, even though it cannot publish a
            // substitution. Avoid that whole-document pass during a wholesale
            // commit while preserving reflow for documents that actually have
            // wrapped paragraphs.
            plan = HardWrapReflow.Plan(ranges: [], substitutions: [])
        }
        let hardWrapSubstitutions = plan.substitutions.filter(\.isHardWrapReflow)
        let logical = DisplayMap(
            paragraphs: paragraphIndex,
            substitutions: hidden.map(DisplaySubstitution.hide)
                + mathSubstitutions
                + inlineImageSubstitutions
                + footnoteSubstitutions
                + lineBreakSubstitutions
                + hardWrapSubstitutions
        )
        return BaseDisplayMaps(
            hidden: hidden,
            hardWrapRanges: plan.ranges,
            hardWrapSubstitutions: hardWrapSubstitutions,
            logical: logical
        )
    }

    /// Hard-wrap planning is only meaningful when a paragraph contains a
    /// physical line break. Checking that invariant once is linear in source
    /// length and avoids a much more expensive character walk through every
    /// single-line paragraph in a large generated document.
    static func containsHardWrappedParagraph(
        in document: ParsedDocument,
        text: NSString
    ) -> Bool {
        var found = false
        document.root.walk { block in
            guard !found, case .paragraph = block.content, block.range.length > 0 else { return }
            found = text.rangeOfCharacter(
                from: .newlines,
                options: [],
                range: block.range
            ).location != NSNotFound
        }
        return found
    }

    static func containsMultilineHTMLParagraph(in document: ParsedDocument, text: NSString) -> Bool {
        var found = false
        document.root.walk { block in
            guard !found, let html = block.safeHTML else { return }
            found = HardWrapReflow.isParagraphLike(block, html: html, text: text)
        }
        return found
    }

    /// Presents safe README structural tags with source-preserving display
    /// replacements. The trailing zero-width joiners keep TextKit source
    /// offsets one-to-one with the replacement, so selection, editing, and
    /// copying continue to address the original tag bytes. Details gets its
    /// authored disclosure state at the opening tag; table rows get a line
    /// break at their closing tag so adjacent cells/rows cannot concatenate.
    static func safeHTMLLineBreakSubstitutions(
        in document: ParsedDocument,
        excluding excludedRange: NSRange?
    ) -> [DisplaySubstitution] {
        var substitutions: [DisplaySubstitution] = []
        document.root.walk { block in
            guard let html = block.safeHTML, html.isSafe else { return }
            for annotation in html.annotations {
                let replacementRange: NSRange
                let replacementText: String
                switch annotation.kind {
                case .lineBreak:
                    guard annotation.range.length > 0 else { continue }
                    replacementRange = annotation.range
                    replacementText = "\n"
                case .details:
                    // Replace only the opening tag, not the content. This
                    // gives both open and closed details a stable native
                    // disclosure marker without changing source bytes.
                    guard let opening = annotation.tagRanges.first,
                          opening.length > 0 else { continue }
                    replacementRange = opening
                    if case .details(let open) = annotation.kind {
                        replacementText = open ? "▾" : "▸"
                    } else {
                        continue
                    }
                case .tableRow:
                    // Rows are often emitted without physical newlines in
                    // README HTML. A break on the closing tag keeps the row
                    // model legible while preserving source coordinates.
                    guard let closing = annotation.tagRanges.last,
                          closing.length > 0 else { continue }
                    replacementRange = closing
                    replacementText = "\n"
                default:
                    continue
                }
                if let excludedRange,
                   NSIntersectionRange(replacementRange, excludedRange).length > 0 {
                    continue
                }
                let replacement = NSAttributedString(string:
                    replacementText + String(repeating: "\u{200B}", count: replacementRange.length - 1)
                )
                substitutions.append(DisplaySubstitution(
                    sourceRange: replacementRange,
                    displayLength: replacementRange.length,
                    replacement: replacement,
                    preservesSourceOffsets: true
                ))
            }
        }
        return substitutions.sorted { $0.sourceRange.location < $1.sourceRange.location }
    }

    /// Removes ranges intersecting an ordered exclusion set in one merge pass.
    /// The old nested `contains` walk made a document with inline math in every
    /// paragraph quadratic while rebuilding its display map.
    static func removingOverlaps(_ ranges: [NSRange], with exclusions: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty, !exclusions.isEmpty else { return ranges }
        let orderedRanges = ranges.sorted { $0.location < $1.location }
        let orderedExclusions = exclusions.sorted { $0.location < $1.location }
        var kept: [NSRange] = []
        kept.reserveCapacity(orderedRanges.count)
        var exclusionIndex = 0
        for range in orderedRanges {
            while exclusionIndex < orderedExclusions.count,
                  orderedExclusions[exclusionIndex].upperBound <= range.location {
                exclusionIndex += 1
            }
            let overlaps = exclusionIndex < orderedExclusions.count
                && orderedExclusions[exclusionIndex].location < range.upperBound
                && orderedExclusions[exclusionIndex].upperBound > range.location
            if !overlaps { kept.append(range) }
        }
        return kept
    }
}

extension PresentationMaps {
    /// `drHidden` mirrors the map so anything reading the storage (rich-text
    /// copy, export, the Quick Look renderer) sees the same decision the layout
    /// did.  `scope == nil` refreshes the document; a range refreshes only that.
    static func applyHiddenAttribute(
        _ hidden: [NSRange], to storage: NSTextStorage, scope: NSRange?, excluding: [NSRange] = []
    ) {
        guard storage.length > 0 else { return }
        let window = scope ?? NSRange(location: 0, length: storage.length)
        guard window.length > 0 else { return }
        storage.beginEditing()
        storage.removeAttribute(.drHidden, range: window)
        for range in RangeSet.intersecting(hidden, window) {
            storage.addAttribute(.drHidden, value: true, range: range)
        }
        for range in RangeSet.intersecting(excluding, window) {
            storage.removeAttribute(.drHidden, range: range)
        }
        storage.endEditing()
    }
}

/// Converts a logical display map into TextKit layout space.
final class LayoutMapBuilder {
    /// TextKit 2 elements keep source-length ranges even when Markdown syntax
    /// is visually omitted. Hidden runs become zero-width word joiners here;
    /// the logical map used by marker policy still collapses them for semantic
    /// selection and reveal decisions.
    func layoutDisplayMap(
        from logical: DisplayMap, paragraphs: ParagraphIndex, storage: NSTextStorage?
    ) -> DisplayMap {
        let substitutions = logical.substitutions.map { layoutSubstitution($0, storage: storage) }
        return DisplayMap(paragraphs: paragraphs, substitutions: substitutions)
    }

    /// One logical substitution in layout space.  Kept separate from the map so
    /// a paragraph-local reveal can transform only its own handful of entries.
    func layoutSubstitution(_ substitution: DisplaySubstitution, storage: NSTextStorage?) -> DisplaySubstitution {
        guard !substitution.isHidden,
              let replacement = substitution.replacement,
              replacement.length < substitution.sourceRange.length,
              replacement.attribute(.attachment, at: 0, effectiveRange: nil) != nil else {
            guard substitution.isHidden else { return substitution }
            return .sourceStyledHidden(substitution.sourceRange)
        }
        let fillerCount = substitution.sourceRange.length - replacement.length
        let layoutReplacement = NSMutableAttributedString(attributedString: replacement)
        layoutReplacement.append(
            layoutFiller(length: fillerCount, styledLike: substitution.sourceRange.location, in: storage)
        )
        return DisplaySubstitution(
            sourceRange: substitution.sourceRange,
            displayLength: substitution.sourceRange.length,
            replacement: layoutReplacement,
            preservesSourceOffsets: true
        )
    }

    /// A run of `length` word joiners carrying the storage's own attributes at
    /// `offset`.
    ///
    /// Reading those attributes with `storage.attributes(at:)` and handing them
    /// to `NSAttributedString(string:attributes:)` bridges one attribute
    /// dictionary out of Objective-C and straight back into it, per hidden
    /// marker, on every keystroke.  On a 5,000-line document that round trip
    /// measured as most of the keystroke budget, and it buys nothing:
    /// `attributedSubstring` hands back the storage's own dictionary without
    /// bridging, and `replaceCharacters` extends the first replaced character's
    /// attributes over the whole replacement.
    private func layoutFiller(length: Int, styledLike offset: Int, in storage: NSTextStorage?) -> NSAttributedString {
        let joiners = wordJoiners(length)
        guard let storage, offset >= 0, offset < storage.length else {
            return NSAttributedString(string: joiners)
        }
        let styled = NSMutableAttributedString(
            attributedString: storage.attributedSubstring(from: NSRange(location: offset, length: 1))
        )
        styled.replaceCharacters(in: NSRange(location: 0, length: 1), with: joiners)
        return styled
    }

    /// Word-joiner runs by length.  A document uses the same handful of marker
    /// lengths over and over — `# `, `- [ ] `, a single `*` — so building the
    /// string once keeps the allocation off the keystroke path.
    private var wordJoinerRuns: [Int: String] = [:]

    private func wordJoiners(_ length: Int) -> String {
        if let cached = wordJoinerRuns[length] { return cached }
        let run = String(repeating: "\u{2060}", count: max(0, length))
        wordJoinerRuns[length] = run
        return run
    }
}
