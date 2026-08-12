import AppKit

private final class MarkdownTextParagraph: NSTextParagraph {
    private let contentRange: NSTextRange
    private let separatorRange: NSTextRange?

    init(
        attributedString: NSAttributedString,
        textContentManager: NSTextContentManager,
        elementRange: NSTextRange,
        separatorRange: NSTextRange?
    ) {
        self.contentRange = elementRange
        self.separatorRange = separatorRange
        super.init(attributedString: attributedString)
        self.textContentManager = textContentManager
        self.elementRange = elementRange
    }

    override var paragraphContentRange: NSTextRange? { contentRange }
    override var paragraphSeparatorRange: NSTextRange? { separatorRange }
}

/// TextKit 2 content storage that can present one Markdown block as one layout
/// element while keeping the source range byte-for-byte intact.
///
/// A normal `NSTextContentStorage` creates one paragraph element per physical
/// newline. Markdown prose often uses those newlines only as source wrapping;
/// grouping the ranges here lets TextKit wrap the prose against the document
/// measure instead. Every replacement published to this storage is
/// source-length preserving, so the element and source coordinate spaces stay
/// aligned during editing.
final class MarkdownContentStorage: NSTextContentStorage {
    private var sourceRanges: [NSRange] = []
    private var elementCache: [Int: NSTextParagraph] = [:]
    private var displayMap: DisplayMap = .identity
    private var usesCustomLayout = false
    private var suspendedCustomLayout = false

    var cachedElementCountForTesting: Int { elementCache.count }

    func configure(
        paragraphIndex: ParagraphIndex,
        reflowRanges: [NSRange],
        displayMap: DisplayMap,
        invalidating invalidatedRanges: [NSRange]? = nil
    ) {
        let previousRanges = sourceRanges
        let previouslyUsedCustomLayout = usesCustomLayout || suspendedCustomLayout
        suspendedCustomLayout = false
        self.displayMap = displayMap
        let length = textStorage?.length ?? paragraphIndex.length
        let ranges = Self.layoutRanges(
            paragraphIndex: paragraphIndex,
            reflowRanges: reflowRanges,
            length: length
        )
        // Only take over layout when the ranges describe the whole document.
        // A partial set is worse than none: TextKit resumes enumeration from
        // the location this storage returns, so ranges that cover nothing (a
        // paragraph index built before the text landed) or leave a gap (a
        // reflow group straddling a paragraph boundary) make it ask for the
        // same location forever and the app stops responding.
        usesCustomLayout = Self.tiles(ranges, length: length)
        if let invalidatedRanges, previouslyUsedCustomLayout, usesCustomLayout {
            // A keystroke changes one element and shifts the ranges after it.
            // Preserve the exact prefix whose source ranges and presentation
            // are unchanged. Throwing every cached element away made TextKit
            // replace resolved layout above the viewport with estimates on
            // every key, which is the root of the full-window shutter.
            elementCache = elementCache.filter { index, _ in
                guard index < previousRanges.count, index < ranges.count,
                      previousRanges[index] == ranges[index] else { return false }
                return !invalidatedRanges.contains {
                    NSIntersectionRange($0, ranges[index]).length > 0
                }
            }
        } else {
            elementCache.removeAll(keepingCapacity: true)
        }
        sourceRanges = usesCustomLayout ? ranges : []
    }

    /// True when `ranges` partition `[0, length)` with no gap and no overlap.
    private static func tiles(_ ranges: [NSRange], length: Int) -> Bool {
        guard length > 0, !ranges.isEmpty else { return false }
        var cursor = 0
        for range in ranges {
            guard range.location == cursor else { return false }
            cursor = range.upperBound
        }
        return cursor == length
    }

    func suspendCustomLayout() {
        suspendedCustomLayout = usesCustomLayout
        usesCustomLayout = false
        displayMap = .identity
    }

    override func enumerateTextElements(
        from textLocation: NSTextLocation?,
        options: NSTextContentManager.EnumerationOptions = [],
        using block: (NSTextElement) -> Bool
    ) -> NSTextLocation? {
        // `configure` already proved the ranges tile the document; re-check only
        // the length, which an edit can move out from under them.
        guard usesCustomLayout,
              let storage = textStorage,
              sourceRanges.last?.upperBound == storage.length
        else {
            return super.enumerateTextElements(from: textLocation, options: options, using: block)
        }

        let reverse = options.contains(.reverse)
        let documentLength = storage.length
        let requestedOffset = textLocation.map {
            offset(from: documentRange.location, to: $0)
        } ?? (reverse ? documentLength : 0)

        // The returned location must move past every element handed to `block`,
        // including the one `block` stopped on.  TextKit resumes enumeration
        // from this location, so returning the requested offset after
        // delivering an element makes the viewport layout loop re-request the
        // same element forever.
        if reverse {
            var index = lastIndex(startingBefore: requestedOffset)
            var edge = requestedOffset
            while index >= 0 {
                let element = element(at: index, storage: storage)
                let wantsMore = block(element)
                edge = sourceRanges[index].location
                if !wantsMore || index == 0 { break }
                index -= 1
            }
            return location(documentRange.location, offsetBy: edge)
        }

        var index = firstIndex(endingAfter: requestedOffset)
        var edge = requestedOffset
        while index < sourceRanges.count {
            let element = element(at: index, storage: storage)
            let wantsMore = block(element)
            edge = sourceRanges[index].upperBound
            index += 1
            if !wantsMore { break }
        }
        return location(documentRange.location, offsetBy: edge)
    }

    /// First element that extends past `offset`, or `count` when none does.
    ///
    /// `configure` guarantees `sourceRanges` tiles `[0, length)` in ascending
    /// order, so `upperBound > offset` is monotone and a binary search is
    /// exact.  These were linear scans, and TextKit reaches this method once
    /// per `ensureLayout` and again per `enumerateTextSegments` — so resolving
    /// a single row's rectangle cost O(elements), and the gutter rail resolving
    /// a screenful of rows cost O(elements²).
    private func firstIndex(endingAfter offset: Int) -> Int {
        var low = 0
        var high = sourceRanges.count
        while low < high {
            let middle = (low + high) / 2
            if sourceRanges[middle].upperBound > offset { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// Last element that begins before `offset`, or the final element when none
    /// does — matching the reverse enumeration's "start from the end" fallback.
    private func lastIndex(startingBefore offset: Int) -> Int {
        guard offset > 0 else { return -1 }
        var low = 0
        var high = sourceRanges.count
        while low < high {
            let middle = (low + high) / 2
            if sourceRanges[middle].location < offset { low = middle + 1 } else { high = middle }
        }
        return low - 1
    }

    private func element(at index: Int, storage: NSTextStorage) -> NSTextParagraph {
        if let cached = elementCache[index] { return cached }

        let sourceRange = sourceRanges[index]
        let anchored = Self.anchoringLeadingStyle(
            displayMap.displayString(forSourceRange: sourceRange, in: storage)
                ?? storage.attributedSubstring(from: sourceRange),
            toSourceOffset: sourceRange.location,
            in: storage
        )
        let attributed = paragraphStyle(for: sourceRange, in: storage).map { style in
            let styled = NSMutableAttributedString(attributedString: anchored)
            styled.addAttribute(
                .paragraphStyle, value: style,
                range: NSRange(location: 0, length: styled.length)
            )
            return styled as NSAttributedString
        } ?? anchored
        guard let start = location(documentRange.location, offsetBy: sourceRange.location),
              let end = location(documentRange.location, offsetBy: sourceRange.upperBound),
              let elementRange = NSTextRange(location: start, end: end) else {
            let paragraph = NSTextParagraph(attributedString: attributed)
            paragraph.textContentManager = self
            return paragraph
        }
        let separatorRange = Self.separatorRange(
            for: sourceRange,
            text: storage.string as NSString,
            documentStart: documentRange.location,
            manager: self
        )
        let paragraph = MarkdownTextParagraph(
            attributedString: attributed,
            textContentManager: self,
            elementRange: elementRange,
            separatorRange: separatorRange
        )
        elementCache[index] = paragraph
        return paragraph
    }

    /// TextKit takes a paragraph's indent, spacing and line height from its
    /// **first character**.  A display substitution can put a synthetic
    /// character there — the space that joins a hard-wrapped line carries no
    /// attributes of its own — and a callout's body starts exactly on the
    /// marker line's terminator, so the whole grouped element then laid out
    /// with no head indent and off the baseline grid: body text sitting on the
    /// callout's own rule.
    ///
    /// Only the leading unstyled run is touched, and only the two attributes
    /// that drive geometry, so a substitution that deliberately styles itself
    /// keeps its own appearance.
    private static func anchoringLeadingStyle(
        _ display: NSAttributedString,
        toSourceOffset offset: Int,
        in storage: NSTextStorage
    ) -> NSAttributedString {
        guard display.length > 0, storage.length > 0 else { return display }
        var head = NSRange(location: 0, length: 0)
        guard display.attribute(.paragraphStyle, at: 0, effectiveRange: &head) == nil else {
            return display
        }
        let anchor = min(max(0, offset), storage.length - 1)
        let source = storage.attributes(at: anchor, effectiveRange: nil)
        let styled = NSMutableAttributedString(attributedString: display)
        if let paragraph = source[.paragraphStyle] {
            styled.addAttribute(.paragraphStyle, value: paragraph, range: head)
        }
        if let font = source[.font] {
            styled.addAttribute(.font, value: font, range: head)
        }
        return styled
    }

    /// The one paragraph style a grouped element should lay out with, or `nil`
    /// when the element is an ordinary paragraph and the storage already says it.
    ///
    /// A grouped element is *one* paragraph spanning several source lines, and
    /// TextKit takes indent, leading and spacing from a single place — so two
    /// things have to be corrected, both of which showed up as the element
    /// laying out in some *other* block's geometry:
    ///
    ///   * **Indent comes from the element's first content, not its first
    ///     character.** A nested item's group opens on the container
    ///     indentation, and those columns belong to the range of the *parent*
    ///     item, so the style found there is the parent's — the child then sat
    ///     at its parent's indent instead of one level in. A callout body opens
    ///     on the terminator of its `> [!KIND]` line, with the same effect.
    ///
    ///   * **Trailing air comes from the last line.** The space after a
    ///     paragraph lives on the physical line that closes it, which is not the
    ///     line TextKit reads, so a reflowed paragraph lost the gap after it.
    private func paragraphStyle(for sourceRange: NSRange, in storage: NSTextStorage) -> NSParagraphStyle? {
        guard sourceRange.length > 0, sourceRange.upperBound <= storage.length else { return nil }
        let text = storage.string as NSString
        let firstLine = text.paragraphRange(for: NSRange(location: sourceRange.location, length: 0))
        let isGrouped = firstLine.upperBound < sourceRange.upperBound
        let contentOffset = firstContentOffset(in: sourceRange)

        guard isGrouped || contentOffset > sourceRange.location else { return nil }
        let base = storage.attribute(.paragraphStyle, at: contentOffset, effectiveRange: nil) as? NSParagraphStyle
        guard let base else { return nil }
        guard isGrouped else { return base }

        let trailing = storage.attribute(.paragraphStyle, at: sourceRange.upperBound - 1, effectiveRange: nil)
            as? NSParagraphStyle
        guard let trailing, trailing.paragraphSpacing != base.paragraphSpacing,
              let unified = base.mutableCopy() as? NSMutableParagraphStyle else { return base }
        unified.paragraphSpacing = trailing.paragraphSpacing
        return unified.copy() as? NSParagraphStyle ?? base
    }

    /// First offset in the element that is not covered by a display
    /// substitution — the first character that contributes glyphs of its own.
    private func firstContentOffset(in sourceRange: NSRange) -> Int {
        var offset = sourceRange.location
        // Ascending and non-overlapping, so one pass resolves a run of adjacent
        // substitutions (a container indent followed by a marker).
        for substitution in displayMap.substitutions(in: sourceRange)
        where substitution.sourceRange.location <= offset && substitution.sourceRange.upperBound > offset {
            offset = substitution.sourceRange.upperBound
        }
        return min(offset, max(sourceRange.location, sourceRange.upperBound - 1))
    }

    private static func separatorRange(
        for sourceRange: NSRange,
        text: NSString,
        documentStart: NSTextLocation,
        manager: NSTextContentManager
    ) -> NSTextRange? {
        guard sourceRange.length > 0 else { return nil }
        let last = text.character(at: sourceRange.upperBound - 1)
        let separatorLength: Int
        switch last {
        case 0x0A:
            separatorLength = sourceRange.length > 1
                && text.character(at: sourceRange.upperBound - 2) == 0x0D ? 2 : 1
        case 0x0D, 0x0085, 0x2028, 0x2029:
            separatorLength = 1
        default:
            guard let end = manager.location(documentStart, offsetBy: sourceRange.upperBound)
            else { return nil }
            return NSTextRange(location: end)
        }
        guard separatorLength <= sourceRange.length,
              let start = manager.location(
                documentStart,
                offsetBy: sourceRange.upperBound - separatorLength
              ),
              let end = manager.location(
                documentStart,
                offsetBy: sourceRange.upperBound
              ) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    private static func layoutRanges(
        paragraphIndex: ParagraphIndex,
        reflowRanges: [NSRange],
        length: Int
    ) -> [NSRange] {
        // `disjoint`, not `normalized`: two reflow groups that merely touch are
        // two paragraphs, and fusing them makes them one element — so a nested
        // item whose group starts exactly where its parent's ends was wrapped
        // into the parent's paragraph and laid out at the parent's indent.
        let groups = RangeSet.disjoint(reflowRanges).filter {
            $0.location >= 0 && $0.upperBound <= length
        }
        var result: [NSRange] = []
        var cursor = 0

        for group in groups {
            appendPhysicalParagraphs(
                from: cursor, to: group.location,
                paragraphIndex: paragraphIndex, into: &result
            )
            result.append(group)
            cursor = group.upperBound
        }
        appendPhysicalParagraphs(
            from: cursor, to: length,
            paragraphIndex: paragraphIndex, into: &result
        )
        return result
    }

    private static func appendPhysicalParagraphs(
        from lower: Int,
        to upper: Int,
        paragraphIndex: ParagraphIndex,
        into result: inout [NSRange]
    ) {
        guard upper > lower else { return }
        let bounds = NSRange(location: lower, length: upper - lower)
        let first = paragraphIndex.index(containing: lower)
        let last = paragraphIndex.index(containing: max(lower, upper - 1))
        for index in first...last {
            // Clip rather than skip.  A reflow group can begin or end inside a
            // physical paragraph; dropping that paragraph would leave a hole in
            // the element ranges, and TextKit needs them to tile the document.
            let clipped = NSIntersectionRange(paragraphIndex.range(at: index), bounds)
            guard clipped.length > 0 else { continue }
            result.append(clipped)
        }
    }
}
