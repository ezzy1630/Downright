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
        let lineIndex = map.line(containing: quoteRange.location)
        let lineRange = map.contentRange(ofLine: lineIndex)
        let line = map.string(ofLine: lineIndex)
        let chars = Array(line)
        var i = 0

        func skipSpaces() { while i < chars.count, chars[i].isMarkdownWhitespace { i += 1 } }

        skipSpaces()
        // Consume the quote markers themselves; a nested `> >` callout is still
        // a callout for the innermost quote.
        var sawMarker = false
        while i < chars.count, chars[i] == ">" {
            sawMarker = true
            i += 1
            if i < chars.count, chars[i] == " " { i += 1 }
        }
        guard sawMarker else { return nil }

        guard i + 2 < chars.count, chars[i] == "[", chars[i + 1] == "!" else { return nil }
        var j = i + 2
        var token = ""
        while j < chars.count, chars[j] != "]" {
            token.append(chars[j])
            j += 1
        }
        guard j < chars.count, chars[j] == "]", let kind = CalloutKind(token: token) else { return nil }
        j += 1
        if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }

        var titleStart = j
        while titleStart < chars.count, chars[titleStart].isMarkdownWhitespace { titleStart += 1 }
        let rawTitle = String(chars[min(titleStart, chars.count)...]).trimmingCharacters(in: .whitespaces)

        // The marker owns everything up to the body, which for a titled callout
        // means the title too — it renders in the panel header, not the body.
        let markerCharacters = rawTitle.isEmpty ? j : chars.count
        let markerUTF16 = String(chars[0..<markerCharacters]).utf16.count
        return CalloutMatch(
            kind: kind,
            title: rawTitle.isEmpty ? nil : rawTitle,
            markerRange: NSRange(location: lineRange.location, length: markerUTF16)
        )
    }
}
