import Foundation
import Markdown

// MARK: - Inline construction
//
// Marker ranges are derived from the *gap* between a span's own range and its
// children's, rather than from a table of delimiter strings.  That single rule
// gets `*em*`, `_em_`, `**strong**`, `__strong__`, `~~strike~~`, `[text](url)`,
// `![alt](src)` and `<autolink>` right without enumerating any of them, which
// matters because §6.1b reveals exactly these ranges and nothing else.

struct InlineBuilder {
    let map: SourceMap
    let lineOffset: Int
    let options: ParseOptions
    let runExtensions: Bool
    /// Footnote identifiers found by the block scan, so `[^1]` can be told
    /// apart from a shortcut link that merely looks like one.
    let footnoteIdentifiers: Set<String>
    private(set) var pathTokens: [ResolvableToken] = []

    init(
        map: SourceMap,
        lineOffset: Int,
        options: ParseOptions,
        runExtensions: Bool,
        footnoteIdentifiers: Set<String>
    ) {
        self.map = map
        self.lineOffset = lineOffset
        self.options = options
        self.runExtensions = runExtensions
        self.footnoteIdentifiers = footnoteIdentifiers
    }

    private var text: NSString { map.text }

    // MARK: Entry point

    /// Inline spans for the children of a leaf text block, covering `bounds`.
    mutating func spans(for markup: Markup, bounds: NSRange) -> [InlineSpan] {
        var built = markup.children.compactMap { span(for: $0) }
        fillBreaks(&built, bounds: bounds)
        return applyExtensions(to: built)
    }

    // MARK: swift-markdown → InlineSpan

    private mutating func span(for markup: Markup) -> InlineSpan? {
        guard let range = map.range(markup.range, lineOffset: lineOffset) else { return nil }
        var children = markup.children.compactMap { span(for: $0) }
        fillBreaks(&children, bounds: range)
        let content = contentRange(of: range, children: children)

        switch markup {
        case is Markdown.Text:
            return InlineSpan(kind: .text, range: range, contentRange: range)

        case is Markdown.SoftBreak:
            return InlineSpan(kind: .softBreak, range: range, contentRange: range)

        case is Markdown.LineBreak:
            return InlineSpan(kind: .lineBreak, range: range, contentRange: range)

        case is Markdown.InlineHTML:
            return InlineSpan(kind: .inlineHTML, range: range, contentRange: range)

        case is Markdown.InlineCode:
            let ticks = backtickRun(at: range)
            let inner = NSRange(
                location: range.location + ticks,
                length: max(0, range.length - 2 * ticks)
            )
            return InlineSpan(
                kind: .inlineCode, range: range, contentRange: inner,
                leadingMarkerRange: ticks > 0 ? NSRange(location: range.location, length: ticks) : nil,
                trailingMarkerRange: ticks > 0 ? NSRange(location: inner.upperBound, length: ticks) : nil,
                children: codeSpanChildren(inner)
            )

        case is Markdown.Emphasis:
            return wrapped(.emphasis, range: range, content: content, children: children)

        case is Markdown.Strong:
            return wrapped(.strong, range: range, content: content, children: children)

        case is Markdown.Strikethrough:
            return wrapped(.strikethrough, range: range, content: content, children: children)

        case let image as Markdown.Image:
            let alt = image.plainText
            return wrapped(
                .image(source: image.source ?? "", alt: alt),
                range: range, content: content, children: children
            )

        case let link as Markdown.Link:
            return linkSpan(link, range: range, content: content, children: children)

        default:
            // Symbol links, custom inlines and inline attributes have no
            // decoration policy of their own; treat them as text so their
            // characters still get covered.
            if children.isEmpty {
                return InlineSpan(kind: .text, range: range, contentRange: range)
            }
            return wrapped(.text, range: range, content: content, children: children)
        }
    }

    private func linkSpan(
        _ link: Markdown.Link, range: NSRange, content: NSRange, children: [InlineSpan]
    ) -> InlineSpan {
        let source = text.substring(with: range)
        if source.hasPrefix("<"), source.hasSuffix(">") {
            return wrapped(
                .autolink(destination: link.destination ?? ""),
                range: range, content: content, children: children
            )
        }
        // A footnote reference reaches us as a link whose text is `^id`,
        // because cmark has no footnote extension enabled and eats the
        // definition as a link reference definition.
        if source.hasPrefix("[^"), let close = source.firstIndex(of: "]") {
            let identifier = String(source[source.index(source.startIndex, offsetBy: 2)..<close])
            if !identifier.isEmpty, footnoteIdentifiers.contains(identifier) {
                return InlineSpan(
                    kind: .footnoteReference(identifier: identifier),
                    range: range, contentRange: content, children: children
                )
            }
        }
        return wrapped(
            .link(destination: link.destination ?? "", title: link.title),
            range: range, content: content, children: children
        )
    }

    private func wrapped(
        _ kind: InlineKind, range: NSRange, content: NSRange, children: [InlineSpan]
    ) -> InlineSpan {
        let leading = content.location > range.location
            ? NSRange(location: range.location, length: content.location - range.location)
            : nil
        let trailing = content.upperBound < range.upperBound
            ? NSRange(location: content.upperBound, length: range.upperBound - content.upperBound)
            : nil
        return InlineSpan(
            kind: kind, range: range, contentRange: content,
            leadingMarkerRange: leading, trailingMarkerRange: trailing,
            children: children
        )
    }

    private func contentRange(of range: NSRange, children: [InlineSpan]) -> NSRange {
        guard let first = children.first, let last = children.last else { return range }
        let lower = max(range.location, first.range.location)
        let upper = min(range.upperBound, last.range.upperBound)
        guard upper >= lower else { return range }
        return NSRange(location: lower, length: upper - lower)
    }

    private func backtickRun(at range: NSRange) -> Int {
        var count = 0
        while count < range.length, text.character(at: range.location + count) == 0x60 { count += 1 }
        return min(count, range.length / 2)
    }

    /// `SoftBreak` and `LineBreak` carry no source range, so `span(for:)` can
    /// never build one and they are absent from the child list.  Reconstruct
    /// them from the newline gaps between siblings: a gap between two spans
    /// that contains a line terminator is exactly where the break sits.
    /// Without this the newline belongs to no span at all — word counts read a
    /// hard-wrapped paragraph as one run-on word, and read-time inherits it.
    private mutating func fillBreaks(_ spans: inout [InlineSpan], bounds: NSRange) {
        guard spans.count > 1 else { return }
        var out: [InlineSpan] = []
        var cursor = bounds.location
        for (index, span) in spans.enumerated() {
            if span.range.location > cursor {
                let gap = NSRange(location: cursor, length: span.range.location - cursor)
                if let kind = breakKind(in: gap) {
                    out.append(InlineSpan(kind: kind, range: gap, contentRange: gap))
                }
            }
            // A backslash (or other) hard break makes swift-markdown anchor the
            // continuation Text at the consumed newline with a zero-length
            // range — the line advance is lost and `offset(line:column:)`
            // clamps it to the end of the *wrong* (previous) line.  Re-anchor
            // it to the physical line the break actually started and give the
            // break a real span.  Guarded by `span.kind == .text` + anchor-is-
            // newline so legitimately empty spans are never touched.
            let nextLocation = index + 1 < spans.count ? spans[index + 1].range.location : NSNotFound
            if let (breakRange, fixed) = reanchoredTextSpan(span, nextLocation: nextLocation, bounds: bounds) {
                out.append(InlineSpan(kind: .lineBreak, range: breakRange, contentRange: breakRange))
                out.append(fixed)
                cursor = fixed.range.upperBound
                continue
            }
            out.append(span)
            cursor = span.range.upperBound
        }
        spans = out
    }

    /// Re-anchor a degenerate `.text` span whose range collapsed to zero-length
    /// onto the line its content actually lives on.  Returns the `LineBreak`
    /// span to insert for the consumed terminator and the corrected text span.
    private func reanchoredTextSpan(
        _ span: InlineSpan, nextLocation: Int, bounds: NSRange
    ) -> (breakRange: NSRange, span: InlineSpan)? {
        guard case .text = span.kind, span.range.length == 0 else { return nil }
        let anchor = span.range.location
        guard anchor >= bounds.location, anchor < bounds.upperBound, isNewline(at: anchor) else { return nil }
        // The break's marker is the newline, plus a trailing backslash if the
        // source wrote one — cover both so the marker is not read as content.
        var breakStart = anchor
        if anchor > bounds.location, text.character(at: anchor - 1) == 0x5C { breakStart = anchor - 1 }
        var breakEnd = anchor + 1
        while breakEnd < bounds.upperBound, isNewline(at: breakEnd) { breakEnd += 1 }
        // The continuation runs to the next physical line end, stopped early by
        // a following sibling span when one is nearer.
        var lineEnd = breakEnd
        while lineEnd < bounds.upperBound, !isNewline(at: lineEnd) { lineEnd += 1 }
        let stop = min(nextLocation > breakEnd ? min(lineEnd, nextLocation) : lineEnd, bounds.upperBound)
        guard stop > breakEnd else { return nil }
        var fixed = span
        fixed.range = NSRange(location: breakEnd, length: stop - breakEnd)
        fixed.contentRange = fixed.range
        return (NSRange(location: breakStart, length: breakEnd - breakStart), fixed)
    }

    private func isNewline(at location: Int) -> Bool {
        let unicode = text.character(at: location)
        return unicode == 0x0A || unicode == 0x0D || unicode == 0x2028 || unicode == 0x2029
    }

    /// The kind of line break a span gap represents, or `nil` if the gap holds
    /// no terminator.  A two-space (or trailing backslash) run before the
    /// terminator is the explicit `LineBreak`; everything else is `SoftBreak`.
    /// The marker spaces may already sit inside the preceding text span (the
    /// gap is often just the newline), so the test looks at the source too.
    ///
    /// Only what precedes the terminator can carry the marker.  Trimming
    /// newlines off the whole gap instead left the *continuation line's
    /// indentation* in play: inside a list item the gap is `"\n   "`, whose
    /// three leading spaces read as the two-space hard break, so every
    /// hard-wrapped line in every list was classified `.lineBreak` — and
    /// `HardWrapReflow` protects those, which cost list prose its reflow
    /// entirely and made `HTMLExporter` emit a `<br>` per wrapped line.
    private func breakKind(in gap: NSRange) -> InlineKind? {
        guard gap.length > 0 else { return nil }
        let source = text.substring(with: gap)
        guard let terminator = source.rangeOfCharacter(from: .newlines) else { return nil }
        let offset = gap.location
        let twoSpacesBefore = offset >= 2
            && text.character(at: offset - 1) == 0x20
            && text.character(at: offset - 2) == 0x20
        let backslashBefore = offset >= 1 && text.character(at: offset - 1) == 0x5C
        let before = String(source[source.startIndex..<terminator.lowerBound])
        if before.hasSuffix("  ") || before.hasSuffix("\\") || twoSpacesBefore || backslashBefore {
            return .lineBreak
        }
        return .softBreak
    }

    // MARK: Extension passes

    private mutating func codeSpanChildren(_ content: NSRange) -> [InlineSpan] {
        guard runExtensions, options.detectPathTokens, content.length > 0 else { return [] }
        guard let match = PathTokenScanner.codeSpanMatch(in: text, range: content) else { return [] }
        pathTokens.append(ResolvableToken(token: match.token, range: match.range, fromCodeSpan: true))
        return [InlineSpan(kind: .pathToken(match.token), range: match.range, contentRange: match.range)]
    }

    private enum Pass { case math, footnote, wikilink, path }

    /// Runs the text-level extension passes in a fixed order.  Each one only
    /// ever splits `.text` spans, so later passes see the leftovers and can
    /// never reach inside code, math or a wikilink target.
    private mutating func applyExtensions(to spans: [InlineSpan]) -> [InlineSpan] {
        guard runExtensions else { return spans }
        var result = spans
        if options.detectMath { result = split(result, pass: .math) }
        if !footnoteIdentifiers.isEmpty { result = split(result, pass: .footnote) }
        if options.detectWikilinks { result = split(result, pass: .wikilink) }
        if options.detectPathTokens { result = split(result, pass: .path) }
        return result
    }

    private mutating func split(_ spans: [InlineSpan], pass: Pass) -> [InlineSpan] {
        var out: [InlineSpan] = []
        out.reserveCapacity(spans.count)
        for var span in spans {
            if case .text = span.kind {
                let replacements = produce(pass, in: span.range)
                if replacements.isEmpty { out.append(span) } else { out.append(contentsOf: replacements) }
            } else {
                span.children = split(span.children, pass: pass)
                out.append(span)
            }
        }
        return out
    }

    private mutating func produce(_ pass: Pass, in range: NSRange) -> [InlineSpan] {
        switch pass {
        case .math:
            let matches = MathScanner.matches(in: text, range: range)
            guard !matches.isEmpty else { return [] }
            return interleave(range, matches.map(\.range)) { index in
                let match = matches[index]
                return InlineSpan(
                    kind: .inlineMath(latexRange: match.contentRange),
                    range: match.range,
                    contentRange: match.contentRange,
                    leadingMarkerRange: NSRange(
                        location: match.range.location,
                        length: match.contentRange.location - match.range.location
                    ),
                    trailingMarkerRange: NSRange(
                        location: match.contentRange.upperBound,
                        length: match.range.upperBound - match.contentRange.upperBound
                    )
                )
            }

        case .footnote:
            // cmark has no footnote extension, so `[^1]` survives as plain text
            // whenever its definition did not happen to parse as a link
            // reference definition.  Match it against the definitions the
            // source scan found so a stray `[^x]` never becomes a dead link.
            let matches = footnoteReferences(in: range)
            guard !matches.isEmpty else { return [] }
            return interleave(range, matches.map(\.0)) { index in
                let (span, identifier) = matches[index]
                let inner = NSRange(location: span.location + 1, length: max(0, span.length - 2))
                return InlineSpan(
                    kind: .footnoteReference(identifier: identifier),
                    range: span, contentRange: inner,
                    leadingMarkerRange: NSRange(location: span.location, length: 1),
                    trailingMarkerRange: NSRange(location: inner.upperBound, length: 1)
                )
            }

        case .wikilink:
            let matches = WikilinkScanner.matches(in: text, range: range)
            guard !matches.isEmpty else { return [] }
            return interleave(range, matches.map(\.range)) { index in
                let match = matches[index]
                let inner = NSRange(
                    location: match.range.location + 2,
                    length: max(0, match.range.length - 4)
                )
                let targetLength = match.targetRange.length
                let hasLabel = match.label != nil
                let leadingLength = hasLabel ? 2 + targetLength + 1 : 2
                let content = hasLabel
                    ? NSRange(
                        location: match.range.location + leadingLength,
                        length: max(0, match.range.length - leadingLength - 2)
                    )
                    : inner
                return InlineSpan(
                    kind: .wikilink(target: match.target, label: match.label),
                    range: match.range,
                    contentRange: content,
                    leadingMarkerRange: NSRange(location: match.range.location, length: leadingLength),
                    trailingMarkerRange: NSRange(location: inner.upperBound, length: 2)
                )
            }

        case .path:
            let matches = PathTokenScanner.matches(in: text, range: range)
            guard !matches.isEmpty else { return [] }
            for match in matches {
                pathTokens.append(
                    ResolvableToken(token: match.token, range: match.range, fromCodeSpan: false)
                )
            }
            return interleave(range, matches.map(\.range)) { index in
                let match = matches[index]
                return InlineSpan(kind: .pathToken(match.token), range: match.range, contentRange: match.range)
            }
        }
    }

    private func footnoteReferences(in range: NSRange) -> [(NSRange, String)] {
        var out: [(NSRange, String)] = []
        var i = range.location
        while i + 3 < range.upperBound {
            guard text.character(at: i) == 0x5B, text.character(at: i + 1) == 0x5E else { i += 1; continue }
            var j = i + 2
            while j < range.upperBound, text.character(at: j) != 0x5D { j += 1 }
            guard j < range.upperBound else { break }
            let identifier = text.substring(with: NSRange(location: i + 2, length: j - i - 2))
            if footnoteIdentifiers.contains(identifier) {
                out.append((NSRange(location: i, length: j + 1 - i), identifier))
                i = j + 1
            } else {
                i += 1
            }
        }
        return out
    }

    /// Rebuilds `range` as alternating plain text and matched spans.
    private func interleave(
        _ range: NSRange, _ matched: [NSRange], _ make: (Int) -> InlineSpan
    ) -> [InlineSpan] {
        var out: [InlineSpan] = []
        var cursor = range.location
        for (index, hit) in matched.enumerated() {
            if hit.location > cursor {
                let gap = NSRange(location: cursor, length: hit.location - cursor)
                out.append(InlineSpan(kind: .text, range: gap, contentRange: gap))
            }
            out.append(make(index))
            cursor = hit.upperBound
        }
        if cursor < range.upperBound {
            let tail = NSRange(location: cursor, length: range.upperBound - cursor)
            out.append(InlineSpan(kind: .text, range: tail, contentRange: tail))
        }
        return out
    }
}

extension InlineSpan {
    /// Drops everything at or before `offset` and clips a span that straddles
    /// it — used when a callout marker is lifted out of the quote's first
    /// paragraph (§4.1).
    static func clipLeading(_ spans: [InlineSpan], to offset: Int) -> [InlineSpan] {
        var out: [InlineSpan] = []
        for var span in spans {
            if span.range.upperBound <= offset { continue }
            if span.range.location < offset {
                let length = span.range.upperBound - offset
                span.range = NSRange(location: offset, length: length)
                span.contentRange = NSRange(
                    location: max(offset, span.contentRange.location),
                    length: max(0, span.contentRange.upperBound - max(offset, span.contentRange.location))
                )
                span.children = clipLeading(span.children, to: offset)
            }
            out.append(span)
        }
        return out
    }
}
