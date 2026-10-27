import Foundation
import MarkdownCore

/// Plans display-only substitutions for soft Markdown line breaks. The
/// renderer keeps this planner separate from live TextKit integration: a
/// replacement must preserve UTF-16 coordinates before it is safe to publish.
enum HardWrapReflow {
    struct Plan {
        var ranges: [NSRange]
        var substitutions: [DisplaySubstitution]
    }

    static func plan(
        document: ParsedDocument,
        text: NSString,
        hiddenRanges: [NSRange],
        excludedRanges: [NSRange] = [],
        enabled: Bool,
        joinsHTMLParagraphs: Bool = false
    ) -> Plan {
        guard enabled || joinsHTMLParagraphs, text.length > 0 else { return Plan(ranges: [], substitutions: []) }

        var ranges: [NSRange] = []
        var substitutions: [DisplaySubstitution] = []
        document.root.walk { block in
            if joinsHTMLParagraphs, let html = block.safeHTML {
                guard !excludedRanges.contains(where: { NSIntersectionRange($0, block.range).length > 0 }),
                      isParagraphLike(block, html: html, text: text),
                      let joined = htmlJoin(block, text: text, hiddenRanges: hiddenRanges)
                else { return }
                ranges.append(joined.range)
                substitutions.append(contentsOf: joined.substitutions)
                return
            }
            guard enabled, case .paragraph = block.content else { return }
            guard !excludedRanges.contains(where: {
                NSIntersectionRange($0, block.range).length > 0
            }) else { return }
            let elementRange = extendedOverHiddenPrefix(
                rangeIncludingTrailingSeparator(for: block, text: text),
                text: text,
                hiddenRanges: hiddenRanges
            )
            let softBreaks = softBreakRanges(
                in: block,
                elementRange: elementRange,
                text: text,
                hiddenRanges: hiddenRanges
            )
            guard !softBreaks.isEmpty else { return }

            ranges.append(elementRange)
            substitutions.append(contentsOf: softBreaks.map {
                .replaceHardWrap($0.terminator, with: softBreakReplacement(
                    for: text, range: $0.terminator, opensElement: $0.terminator.location == elementRange.location
                ))
            })
            // The indentation belongs to the *next* physical paragraph, so it
            // cannot ride along in the terminator's substitution — `DisplayMap`
            // refuses an entry that crosses a paragraph boundary.  It gets its
            // own zero-width, length-preserving entry instead.
            substitutions.append(contentsOf: softBreaks.flatMap(\.indents).map {
                .replaceHardWrap($0, with: zeroWidthReplacement(length: $0.length))
            })

            let joined = softBreaks.flatMap { [$0.terminator] + $0.indents }
            for hidden in hiddenRanges where hidden.location >= elementRange.location
                && hidden.upperBound <= elementRange.upperBound {
                guard !joined.contains(where: { NSIntersectionRange($0, hidden).length > 0 }) else {
                    continue
                }
                substitutions.append(
                    .replaceHidden(hidden, with: zeroWidthReplacement(length: hidden.length))
                )
            }
        }

        return Plan(ranges: ranges.sorted { $0.location < $1.location }, substitutions: substitutions)
    }

    // MARK: - HTML paragraphs

    /// A `<p>` or heading HTML block whose element spans the whole block:
    /// README rows of links and badges, one `<a>` per source line.
    static func isParagraphLike(_ block: MDBlock, html: SafeHTMLDocument, text: NSString) -> Bool {
        guard html.isSafe, block.range.length > 0, block.range.upperBound <= text.length else { return false }
        var start = block.range.location
        var end = block.range.upperBound
        while start < end, isWhitespace(text.character(at: start)) { start += 1 }
        while end > start, isWhitespace(text.character(at: end - 1)) { end -= 1 }
        guard text.range(of: "\n", options: [], range: NSRange(location: start, length: end - start)).location
                != NSNotFound else { return false }
        return html.annotations.contains { annotation in
            switch annotation.kind {
            case .paragraph, .heading:
                return annotation.range.location == start && annotation.range.upperBound >= end
            default:
                return false
            }
        }
    }

    /// HTML's whitespace rule for one paragraph-like block: a run of line
    /// breaks and indentation between two pieces of visible content shows as
    /// one space; at the start or end of the block, or around a line that
    /// holds only hidden tags, it shows as nothing.  So
    ///
    ///     <p align="center">
    ///       <a href="…"><img …></a>
    ///       <a href="…"><img …></a>
    ///     </p>
    ///
    /// reads as one centred line of badges, as it does on GitHub.
    private static func htmlJoin(
        _ block: MDBlock, text: NSString, hiddenRanges: [NSRange]
    ) -> (range: NSRange, substitutions: [DisplaySubstitution])? {
        let elementRange = rangeIncludingTrailingSeparator(for: block, text: text)
        let upperBound = Swift.min(elementRange.upperBound, text.length)
        let hidden = hiddenRanges.filter {
            $0.location >= elementRange.location && $0.upperBound <= elementRange.upperBound
        }

        // Physical lines inside the block, and whether each shows anything.
        var lines: [(content: NSRange, terminator: NSRange?)] = []
        var lineStart = block.range.location
        var cursor = lineStart
        while cursor < upperBound {
            let length = lineTerminatorLength(in: text, at: cursor)
            guard length > 0 else { cursor += 1; continue }
            lines.append((NSRange(location: lineStart, length: cursor - lineStart),
                          NSRange(location: cursor, length: length)))
            cursor += length
            lineStart = cursor
        }
        if lineStart < upperBound {
            lines.append((NSRange(location: lineStart, length: upperBound - lineStart), nil))
        }
        let visible = lines.map { showsContent($0.content, text: text, hidden: hidden) }

        var substitutions: [DisplaySubstitution] = []
        var joined: [NSRange] = []
        var contentSinceSpace = false
        for (index, line) in lines.enumerated() {
            if visible[index] { contentSinceSpace = true }
            // The block's own closing newline separates it from the next
            // block; it is not joined.
            guard let terminator = line.terminator, terminator.upperBound < elementRange.upperBound else { continue }
            let contentFollows = visible[(index + 1)...].contains(true)
            let replacement: NSAttributedString
            if contentSinceSpace, contentFollows {
                replacement = softBreakReplacement(for: text, range: terminator, opensElement: false)
                contentSinceSpace = false
            } else {
                replacement = zeroWidthReplacement(length: terminator.length)
            }
            substitutions.append(.replaceHardWrap(terminator, with: replacement))
            joined.append(terminator)
            let indents = continuationIndents(
                after: terminator, limit: elementRange.upperBound, text: text, hiddenRanges: hidden)
            substitutions.append(contentsOf: indents.map {
                .replaceHardWrap($0, with: zeroWidthReplacement(length: $0.length))
            })
            joined.append(contentsOf: indents)
        }
        guard !joined.isEmpty else { return nil }
        for range in hidden where !joined.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
            substitutions.append(.replaceHidden(range, with: zeroWidthReplacement(length: range.length)))
        }
        return (elementRange, substitutions)
    }

    /// Whether any character of `line` is neither whitespace nor hidden.
    private static func showsContent(_ line: NSRange, text: NSString, hidden: [NSRange]) -> Bool {
        var cursor = line.location
        while cursor < line.upperBound {
            if let range = hidden.first(where: { $0.location <= cursor && $0.upperBound > cursor }) {
                cursor = range.upperBound
                continue
            }
            if !isWhitespace(text.character(at: cursor)) { return true }
            cursor += 1
        }
        return false
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        isHorizontalWhitespace(character) || character == 0x0A || character == 0x0D
    }

    /// A soft break to join, together with the continuation line's own
    /// indentation.  The two are separate ranges because they sit on either
    /// side of a paragraph boundary, but they are one editorial decision: the
    /// join is only correct if the indentation disappears with the newline.
    /// Leaving it behind put three spaces in the middle of every sentence a
    /// list item wrapped.
    private struct SoftBreak {
        var terminator: NSRange
        var indents: [NSRange]
    }

    /// Returns the paragraph's hard line breaks that may be softened, in
    /// order.  A break inside an inline code, math, HTML or explicit-break
    /// span is *skipped*, not fatal: one `inline code` spanning two lines must
    /// not cost the whole paragraph its reflow.
    private static func softBreakRanges(
        in block: MDBlock,
        elementRange: NSRange,
        text: NSString,
        hiddenRanges: [NSRange]
    ) -> [SoftBreak] {
        var result: [SoftBreak] = []
        let upperBound = Swift.min(elementRange.upperBound, text.length)
        var cursor = Swift.max(0, block.range.location)
        while cursor < upperBound {
            let length = lineTerminatorLength(in: text, at: cursor)
            guard length > 0 else {
                cursor += 1
                continue
            }
            let range = NSRange(location: cursor, length: length)
            guard range.upperBound < elementRange.upperBound else { break }
            if isProtected(range, in: block.inlines) {
                cursor = range.upperBound
                continue
            }
            if isExplicitBreak(range, in: text) {
                cursor = range.upperBound
                continue
            }
            result.append(SoftBreak(
                terminator: range,
                indents: continuationIndents(
                    after: range, limit: elementRange.upperBound,
                    text: text, hiddenRanges: hiddenRanges
                )
            ))
            cursor = range.upperBound
        }
        return result
    }

    /// The indentation runs that open the continuation line, in order.
    ///
    /// A hidden line prefix — the `> ` of a quote or callout — is already
    /// zero-width, so this steps over it and keeps looking for indentation
    /// behind it.  That is what makes a hard-wrapped list *inside* a callout
    /// join as cleanly as one at the top level.
    private static func continuationIndents(
        after terminator: NSRange,
        limit: Int,
        text: NSString,
        hiddenRanges: [NSRange]
    ) -> [NSRange] {
        var runs: [NSRange] = []
        // A stale parsed document can outlive the buffer it was parsed from, so
        // the caller's limit may run past `text.length`; clamp before indexing.
        let limit = Swift.min(limit, text.length)
        var cursor = terminator.upperBound
        while cursor < limit {
            if let hidden = hiddenRanges.first(where: { $0.location == cursor }), hidden.length > 0 {
                cursor = Swift.min(hidden.upperBound, limit)
                continue
            }
            let start = cursor
            while cursor < limit, isHorizontalWhitespace(text.character(at: cursor)) {
                cursor += 1
            }
            guard cursor > start else { break }
            runs.append(NSRange(location: start, length: cursor - start))
        }
        return runs
    }

    private static func isHorizontalWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }

    private static func rangeIncludingTrailingSeparator(for block: MDBlock, text: NSString) -> NSRange {
        let length = lineTerminatorLength(in: text, at: block.range.upperBound)
        guard length > 0, block.range.upperBound + length <= text.length else { return block.range }
        return NSRange(location: block.range.location, length: block.range.length + length)
    }

    /// Extends a group backwards across a hidden line prefix.
    ///
    /// A list item's paragraph starts *after* its `3. `, so the marker would be
    /// clipped into a physical paragraph of its own — and a grouped element
    /// beside it is a separate line, which put the marker on one row and the
    /// item's first word on the next.  The marker is hidden syntax the ornament
    /// fragment draws in the hanging column, so folding it into the group costs
    /// nothing and keeps the item on one row.
    ///
    /// Refused when the group already opens on a terminator (a quoted or
    /// callout paragraph, whose range begins at the newline of the line above):
    /// extending there would swallow the `> [!NOTE]` header line that
    /// `CalloutFragment` requires to be an element of its own.
    private static func extendedOverHiddenPrefix(
        _ range: NSRange, text: NSString, hiddenRanges: [NSRange]
    ) -> NSRange {
        guard range.location > 0,
              range.location < text.length,
              lineTerminatorLength(in: text, at: range.location) == 0 else { return range }
        let start = lineStart(before: range.location, in: text)
        guard start < range.location else { return range }
        var cursor = start
        while cursor < range.location {
            if let hidden = hiddenRanges.first(where: { $0.location <= cursor && $0.upperBound > cursor }) {
                cursor = hidden.upperBound
                continue
            }
            guard isHorizontalWhitespace(text.character(at: cursor)) else { return range }
            cursor += 1
        }
        return NSRange(location: start, length: range.upperBound - start)
    }

    /// The first character of the physical line containing `offset`.
    private static func lineStart(before offset: Int, in text: NSString) -> Int {
        var cursor = Swift.min(offset, text.length)
        while cursor > 0, lineTerminatorLength(in: text, at: cursor - 1) == 0 {
            cursor -= 1
        }
        return cursor
    }

    private static func isProtected(_ range: NSRange, in spans: [InlineSpan]) -> Bool {
        var protected = false
        walk(spans) { span in
            guard span.range.location <= range.location,
                  span.range.upperBound >= range.upperBound else { return }
            switch span.kind {
            case .inlineCode, .inlineMath, .inlineHTML, .lineBreak:
                protected = true
            default:
                break
            }
        }
        return protected
    }

    private static func walk(_ spans: [InlineSpan], visit: (InlineSpan) -> Void) {
        for span in spans {
            visit(span)
            walk(span.children, visit: visit)
        }
    }

    private static func lineTerminatorLength(in text: NSString, at offset: Int) -> Int {
        guard offset >= 0, offset < text.length else { return 0 }
        let character = text.character(at: offset)
        guard character == 0x0A || character == 0x0D
                || character == 0x0085 || character == 0x2028 || character == 0x2029
        else { return 0 }
        if character == 0x0D, offset + 1 < text.length, text.character(at: offset + 1) == 0x0A {
            return 2
        }
        return 1
    }

    private static func isExplicitBreak(_ range: NSRange, in text: NSString) -> Bool {
        let before = range.location
        if before >= 1, text.character(at: before - 1) == 0x5C { return true }
        return before >= 2
            && text.character(at: before - 1) == 0x20
            && text.character(at: before - 2) == 0x20
    }

    /// One space, padded to the terminator's own length so the substitution
    /// preserves UTF-16 coordinates.  Every terminator collapses to a *single*
    /// space: a CRLF that became two spaces put a double space into the joined
    /// sentence on Windows-authored files.
    ///
    /// A terminator that *opens* the element joins nothing — a quoted or callout
    /// paragraph's range begins at the newline ending the line above it — so it
    /// contributes no space.  As one it indented the first line of every callout
    /// body by a space relative to the lines under it.
    private static func softBreakReplacement(
        for text: NSString, range: NSRange, opensElement: Bool
    ) -> NSAttributedString {
        guard !opensElement else { return zeroWidthReplacement(length: range.length) }
        guard range.length > 1 else { return NSAttributedString(string: " ") }
        return NSAttributedString(string: " " + String(repeating: "\u{200B}", count: range.length - 1))
    }

    private static func zeroWidthReplacement(length: Int) -> NSAttributedString {
        NSAttributedString(string: String(repeating: "\u{200B}", count: max(1, length)))
    }
}
