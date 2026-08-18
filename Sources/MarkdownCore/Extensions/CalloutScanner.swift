import Foundation

// MARK: - Callouts (§4.1)
//
// `> [!NOTE]`, `> [!WARNING] Optional title`.  Agents emit these constantly, so
// a blockquote that opens with one becomes a `.callout` rather than a
// `.blockQuote` and the marker line is lifted out of the body text.
//
// Matching is case-insensitive and tolerates the Obsidian fold suffixes
// (`[!NOTE]+` / `[!NOTE]-`) because they appear in the wild and dropping the
// document to a plain quote over one character would be a poor trade.

struct CalloutMatch {
    var kind: CalloutKind
    var title: String?
    /// `> [!NOTE] Title` including the trailing space, if any — the gutter
    /// marker for §6.1a.
    var markerRange: NSRange
}

enum CalloutScanner {
    /// Inspects the first line of a blockquote whose range starts at `start`.
    static func scan(_ map: SourceMap, quoteRange: NSRange) -> CalloutMatch? {
        let text = map.text
        let lineIndex = map.line(containing: quoteRange.location)
        let lineRange = map.contentRange(ofLine: lineIndex)
        let start = lineRange.location
        let end = lineRange.upperBound
        var i = start

        func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }
        while i < end, isSpace(text.character(at: i)) { i += 1 }

        // Consume the quote markers themselves; a nested `> >` callout is still
        // a callout for the innermost quote.
        var sawMarker = false
        while i < end {
            while i < end, isSpace(text.character(at: i)) { i += 1 }
            guard i < end, text.character(at: i) == 0x3E else { break }
            sawMarker = true
            i += 1
        }
        guard sawMarker else { return nil }
        while i < end, isSpace(text.character(at: i)) { i += 1 }

        guard i + 2 < end, text.character(at: i) == 0x5B, text.character(at: i + 1) == 0x21 else { return nil }
        var j = i + 2
        while j < end, text.character(at: j) != 0x5D { j += 1 }
        guard j < end, let kind = CalloutKind(token: text.substring(with: NSRange(location: i + 2, length: j - i - 2)))
        else { return nil }
        j += 1
        if j < end, text.character(at: j) == 0x2B || text.character(at: j) == 0x2D { j += 1 }

        var titleStart = j
        while titleStart < end, isSpace(text.character(at: titleStart)) { titleStart += 1 }
        let rawTitle = text.substring(with: NSRange(location: titleStart, length: end - titleStart))
            .trimmingCharacters(in: .whitespaces)

        // The marker owns everything up to the body, which for a titled callout
        // means the title too — it renders in the panel header, not the body.
        let markerLength = rawTitle.isEmpty ? j - start : end - start
        return CalloutMatch(
            kind: kind,
            title: rawTitle.isEmpty ? nil : rawTitle,
            markerRange: NSRange(location: lineRange.location, length: markerLength)
        )
    }
}
