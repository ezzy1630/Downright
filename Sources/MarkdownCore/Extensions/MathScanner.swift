import Foundation

// MARK: - Math (§4.1)
//
// `$` is everywhere in shell snippets, prices and template syntax, so the
// delimiter rules matter more than the parsing does.  A false positive turns a
// paragraph of prose into a broken glyph, which is far worse than a missed
// formula.  The `\(…\)` and `\[…\]` forms are unambiguous and get relaxed rules.
//
// This scanner only ever runs over `.text` inline spans, so code spans and
// fenced code are structurally out of reach — it cannot match inside them.

struct MathMatch {
    /// Whole match including delimiters.
    var range: NSRange
    /// The LaTeX between the delimiters.
    var contentRange: NSRange
    var isDisplay: Bool
}

enum MathScanner {
    /// All math in `range` of `text`, in ascending order and non-overlapping.
    static func matches(in text: NSString, range: NSRange) -> [MathMatch] {
        var out: [MathMatch] = []
        var i = range.location
        let end = range.upperBound

        while i < end {
            let ch = text.character(at: i)
            if ch == 0x5C {  // backslash — `\(`, `\[`
                if let match = escapedDelimiter(text, at: i, end: end) {
                    out.append(match)
                    i = match.range.upperBound
                    continue
                }
                i += 2  // any other escape consumes its escapee
                continue
            }
            if ch == 0x24 {  // `$`
                if let match = dollar(text, at: i, end: end, rangeStart: range.location) {
                    out.append(match)
                    i = match.range.upperBound
                    continue
                }
            }
            i += 1
        }
        return out
    }

    /// `\(inline\)` and `\[display\]`.
    private static func escapedDelimiter(_ text: NSString, at start: Int, end: Int) -> MathMatch? {
        guard let next = text.character(safeAt: start + 1) else { return nil }
        let isDisplay: Bool
        let closer: unichar
        switch next {
        case 0x28: isDisplay = false; closer = 0x29  // ( )
        case 0x5B: isDisplay = true; closer = 0x5D   // [ ]
        default: return nil
        }
        var i = start + 2
        while i + 1 < end {
            if text.character(at: i) == 0x5C, text.character(at: i + 1) == closer {
                var backslashCount = 0
                var p = i
                while p >= start + 2, text.character(at: p) == 0x5C {
                    backslashCount += 1
                    p -= 1
                }
                if backslashCount % 2 == 1 {
                    let content = NSRange(location: start + 2, length: i - (start + 2))
                    guard content.length > 0 else { return nil }
                    return MathMatch(
                        range: NSRange(location: start, length: i + 2 - start),
                        contentRange: content,
                        isDisplay: isDisplay
                    )
                }
            }
            i += 1
        }
        return nil
    }

    /// `$inline$` and `$$display$$`, with the shell-hostile guard rails.
    private static func dollar(_ text: NSString, at start: Int, end: Int, rangeStart: Int) -> MathMatch? {
        // An escaped `\$` is not a delimiter.
        if start > rangeStart, text.character(at: start - 1) == 0x5C { return nil }

        let isDisplay = text.character(safeAt: start + 1) == 0x24
        let delimiterLength = isDisplay ? 2 : 1
        // A digit immediately before the opener means we are inside a number.
        if let previous = text.character(safeAt: start - 1), isDigit(previous) { return nil }

        var i = start + delimiterLength
        while i < end {
            let ch = text.character(at: i)
            if ch == 0x5C { i += 2; continue }
            if ch == 0x24 {
                if isDisplay {
                    guard text.character(safeAt: i + 1) == 0x24 else { i += 1; continue }
                } else if text.character(safeAt: i + 1) == 0x24 {
                    // `$x$$` — not a plausible inline close.
                    return nil
                }
                let content = NSRange(location: start + delimiterLength, length: i - start - delimiterLength)
                let closeEnd = i + delimiterLength
                guard isPlausible(text, content: content, closeEnd: closeEnd, isDisplay: isDisplay) else { return nil }
                return MathMatch(
                    range: NSRange(location: start, length: closeEnd - start),
                    contentRange: content,
                    isDisplay: isDisplay
                )
            }
            i += 1
        }
        return nil
    }

    /// The rules that keep `echo $PATH`, `$5 and $10` and `$(cmd)` out.
    private static func isPlausible(_ text: NSString, content: NSRange, closeEnd: Int, isDisplay: Bool) -> Bool {
        guard content.length > 0 else { return false }
        let body = text.substring(with: content)

        // `$$…$$` is nearly always written on its own lines, so its content is
        // legitimately surrounded by newlines and only needs to be non-blank.
        // The tight rules below exist to disambiguate a single `$`, which `$$`
        // does not suffer from.
        if isDisplay { return !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if body.contains("\n") { return false }
        // `$5 and $10` closes on content that ends in a space.  Requiring the
        // content to be flush against both delimiters kills that whole class.
        guard let first = body.first, let last = body.last,
              !first.isWhitespace, !last.isWhitespace else { return false }
        // A bare amount: `$100$` is money in a table far more often than maths.
        if body.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }) { return false }
        // `$5$10` — a digit right after the closer means we split a number.
        if let after = text.character(safeAt: closeEnd), isDigit(after) { return false }
        return true
    }

    private static func isDigit(_ ch: unichar) -> Bool { ch >= 0x30 && ch <= 0x39 }

    /// A whole-paragraph display block: `$$…$$` or `\[…\]` with nothing else
    /// around it.  Rendered as a centred block rather than an inline glyph.
    static func wholeBlock(in text: NSString, range: NSRange) -> MathMatch? {
        var start = range.location
        var end = range.upperBound
        while start < end, isSpace(text.character(at: start)) { start += 1 }
        while end > start, isSpace(text.character(at: end - 1)) { end -= 1 }
        guard end > start else { return nil }
        let trimmed = NSRange(location: start, length: end - start)
        guard let match = matches(in: text, range: trimmed).first,
              match.isDisplay,
              match.range == trimmed
        else { return nil }
        return match
    }

    private static func isSpace(_ ch: unichar) -> Bool {
        ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D
    }
}

// MARK: - Display math in a table cell
//
// A table cell cannot hold a newline, so display math there is written
// `$$ <br> expression <br> $$`. cmark makes each `<br>` inline HTML before
// the math pass, which scans one text span at a time, so neither `$$` sees
// its partner. Only a whole cell of exactly that shape is math: the breaks
// must sit between the delimiters and the expression, the expression must be
// plain text, and anything else (other HTML, code, a second formula) keeps
// the cell as written.

extension MathScanner {
    /// One display-math span for a cell made only of `$$`, breaks, a plain
    /// expression, breaks and `$$`; nil for any other cell. Linear in the
    /// cell, and a plain cell leaves at the first check.
    static func breakPaddedCellMath(_ spans: [InlineSpan], in text: NSString) -> InlineSpan? {
        // `$$` text, a break, the expression, a break, `$$` text: five spans at least.
        guard spans.count >= 5, let first = spans.first, let last = spans.last,
              case .text = first.kind, case .text = last.kind,
              spans.contains(where: { if case .inlineHTML = $0.kind { return true }; return false })
        else { return nil }
        let whole = NSRange(location: first.range.location,
                            length: last.range.upperBound - first.range.location)
        guard whole.length >= 6, whole.upperBound <= text.length,
              text.character(at: whole.location) == 0x24, text.character(at: whole.location + 1) == 0x24,
              text.character(at: whole.upperBound - 1) == 0x24, text.character(at: whole.upperBound - 2) == 0x24
        else { return nil }

        // cmark decides what is HTML; only a break may be, and only as padding.
        var breaks: [NSRange] = []
        for span in spans {
            switch span.kind {
            case .text: continue
            case .inlineHTML where isLineBreakTag(text.substring(with: span.range)):
                breaks.append(span.range)
            default: return nil
            }
        }
        func isBlank(_ offset: Int) -> Bool {
            let ch = text.character(at: offset)
            return ch == 0x20 || ch == 0x09
        }
        // Walk in from each `$$` over blanks and breaks; at least one break
        // on each side, and the expression is what remains between them.
        // `breaks` is in source order, so each side consumes it from its own
        // end with an index: every break is looked at once.
        var start = whole.location + 2
        var leadingBreaks = 0
        while start < whole.upperBound - 2 {
            if isBlank(start) { start += 1 }
            else if leadingBreaks < breaks.count, breaks[leadingBreaks].location == start {
                start = breaks[leadingBreaks].upperBound
                leadingBreaks += 1
            } else { break }
        }
        var end = whole.upperBound - 2
        var trailingBreaks = 0
        while end > start {
            let next = breaks.count - 1 - trailingBreaks
            if isBlank(end - 1) { end -= 1 }
            else if next >= leadingBreaks, breaks[next].upperBound == end {
                end = breaks[next].location
                trailingBreaks += 1
            } else { break }
        }
        let body = NSRange(location: start, length: end - start)
        guard leadingBreaks > 0, trailingBreaks > 0, body.length > 0,
              breaks.allSatisfy({ NSIntersectionRange($0, body).length == 0 }),
              text.range(of: "$$", options: .literal, range: body).location == NSNotFound
        else { return nil }
        return InlineSpan(
            kind: .inlineMath(latexRange: body),
            range: whole,
            contentRange: body,
            leadingMarkerRange: NSRange(location: whole.location, length: body.location - whole.location),
            trailingMarkerRange: NSRange(location: body.upperBound, length: whole.upperBound - body.upperBound)
        )
    }

    /// `<br>`, `<br/>` or `<br />`, in any case.
    private static func isLineBreakTag(_ tag: String) -> Bool {
        let lower = tag.lowercased()
        guard lower.hasPrefix("<br"), lower.hasSuffix(">"), lower.count >= 4 else { return false }
        let inside = lower.dropFirst(3).dropLast().trimmingCharacters(in: .whitespaces)
        return inside.isEmpty || inside == "/"
    }
}
