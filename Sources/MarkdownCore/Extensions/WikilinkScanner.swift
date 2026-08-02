import Foundation

// MARK: - Wikilinks (§4.1)
//
// `[[Name]]` and `[[Name|Label]]`.  §2 is explicit that rendering these as
// links is in scope and indexing them is not, so this produces a span and
// nothing else — no registry, no backlink table.
//
// cmark leaves `[[Name]]` as literal text (there is no matching reference
// definition), so this scanner only ever sees `.text` spans and cannot match
// inside code.

struct WikilinkMatch {
    var range: NSRange
    /// Text between the brackets, before any `|`.
    var targetRange: NSRange
    var target: String
    var label: String?
}

enum WikilinkScanner {
    static func matches(in text: NSString, range: NSRange) -> [WikilinkMatch] {
        var out: [WikilinkMatch] = []
        var i = range.location
        let end = range.upperBound
        while i + 3 < end {
            guard text.character(at: i) == 0x5B, text.character(at: i + 1) == 0x5B else {
                i += 1
                continue
            }
            guard let close = closing(text, from: i + 2, end: end) else {
                i += 1
                continue
            }
            let inner = NSRange(location: i + 2, length: close - (i + 2))
            let body = text.substring(with: inner)
            if !body.isEmpty, !body.contains("\n") {
                let parts = body.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                let target = parts[0].trimmingCharacters(in: .whitespaces)
                let label = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
                if !target.isEmpty {
                    out.append(WikilinkMatch(
                        range: NSRange(location: i, length: close + 2 - i),
                        targetRange: NSRange(location: inner.location, length: parts[0].utf16.count),
                        target: target,
                        label: label.flatMap { $0.isEmpty ? nil : $0 }
                    ))
                    i = close + 2
                    continue
                }
            }
            i += 2
        }
        return out
    }

    private static func closing(_ text: NSString, from start: Int, end: Int) -> Int? {
        var i = start
        while i + 1 < end {
            let ch = text.character(at: i)
            if ch == 0x5D, text.character(at: i + 1) == 0x5D { return i }
            if ch == 0x5B { return nil }  // a nested `[` means this is not a wikilink
            i += 1
        }
        return nil
    }
}
