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

    func configure(
        paragraphIndex: ParagraphIndex,
        reflowRanges: [NSRange],
        displayMap: DisplayMap
    ) {
        self.displayMap = displayMap
        sourceRanges = Self.layoutRanges(
            paragraphIndex: paragraphIndex,
            reflowRanges: reflowRanges,
            length: textStorage?.length ?? paragraphIndex.length
        )
        elementCache.removeAll(keepingCapacity: true)
        usesCustomLayout = !sourceRanges.isEmpty
    }

    func suspendCustomLayout() {
        usesCustomLayout = false
        sourceRanges.removeAll(keepingCapacity: true)
        elementCache.removeAll(keepingCapacity: true)
        displayMap = .identity
    }

    override func enumerateTextElements(
        from textLocation: NSTextLocation?,
        options: NSTextContentManager.EnumerationOptions = [],
        using block: (NSTextElement) -> Bool
    ) -> NSTextLocation? {
        guard usesCustomLayout,
              let storage = textStorage,
              !sourceRanges.isEmpty,
              sourceRanges.allSatisfy({ $0.upperBound <= storage.length })
        else {
            return super.enumerateTextElements(from: textLocation, options: options, using: block)
        }

        let reverse = options.contains(.reverse)
        let documentLength = storage.length
        let requestedOffset = textLocation.map {
            offset(from: documentRange.location, to: $0)
        } ?? (reverse ? documentLength : 0)

        if reverse {
            var index = sourceRanges.lastIndex { $0.location < requestedOffset }
                ?? sourceRanges.count - 1
            var edge = requestedOffset
            while index >= 0 {
                let element = element(at: index, storage: storage)
                guard block(element) else { break }
                edge = sourceRanges[index].location
                if index == 0 { break }
                index -= 1
            }
            return location(documentRange.location, offsetBy: edge)
        }

        var index = sourceRanges.firstIndex { $0.upperBound > requestedOffset } ?? sourceRanges.count
        var edge = requestedOffset
        while index < sourceRanges.count {
            let element = element(at: index, storage: storage)
            guard block(element) else { break }
            edge = sourceRanges[index].upperBound
            index += 1
        }
        return location(documentRange.location, offsetBy: edge)
    }

    private func element(at index: Int, storage: NSTextStorage) -> NSTextParagraph {
        if let cached = elementCache[index] { return cached }

        let sourceRange = sourceRanges[index]
        let attributed = displayMap.displayString(forSourceRange: sourceRange, in: storage)
            ?? storage.attributedSubstring(from: sourceRange)
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
        let groups = RangeSet.normalized(reflowRanges).filter {
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
        let first = paragraphIndex.index(containing: lower)
        let last = paragraphIndex.index(containing: max(lower, upper - 1))
        for index in first...last {
            let range = paragraphIndex.range(at: index)
            guard range.location >= lower, range.upperBound <= upper else { continue }
            result.append(range)
        }
    }
}
