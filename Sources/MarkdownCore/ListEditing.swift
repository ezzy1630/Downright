import Foundation

// MARK: - List editing (§6.4)
//
// "List continuation on ⏎; outdent-and-exit on an empty item.  ⇥/⇧⇥ indent and
// outdent list items, renumbering ordered lists automatically."
//
// Continuation is expressed as a replacement rather than an insertion so that
// the empty-item case — where pressing ⏎ *removes* the marker instead of adding
// one — goes through the same path and the same undo grouping.

public struct ListContinuation: Sendable {
    public var replaceRange: NSRange
    public var insertion: String

    public init(replaceRange: NSRange, insertion: String) {
        self.replaceRange = replaceRange
        self.insertion = insertion
    }
}

public enum ListEditing {
    /// Result of pressing Return at `offset` inside a list item (§6.4).
    /// Returns nil when the caret is not in a list.
    public static func continuation(_ doc: ParsedDocument, at offset: Int) -> ListContinuation? {
        guard let item = enclosingItem(doc, offset: offset),
              let marker = item.markerRange,
              case .listItem(let ordinal, let checkbox) = item.content
        else { return nil }

        let text = doc.text as NSString
        let lineNumber = doc.line(at: marker.location)
        let lineRange = doc.range(ofLine: lineNumber)
        let source = doc.substring(lineRange)
        let indent = source.leadingIndent
        let markerText = text.substring(with: marker)
        let body = text.substring(with: NSRange(
            location: marker.upperBound,
            length: max(0, item.range.upperBound - marker.upperBound)
        ))

        // An empty item ends the list.  Outdent one level if it is nested,
        // otherwise clear the marker and leave a blank line behind.  The whole
        // line is replaced because an empty item is nothing but its marker, so
        // there is no content to preserve.
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard !indent.isEmpty else {
                return ListContinuation(replaceRange: lineRange, insertion: "")
            }
            let bullet = markerText.trimmingCharacters(in: .whitespaces)
            let outdented = String(indent.dropLast(min(indent.count, 2)))
            return ListContinuation(replaceRange: lineRange, insertion: outdented + bullet + " ")
        }

        var next = indent
        if let ordinal {
            let punctuation = markerText.contains(")") ? ")" : "."
            next += "\(ordinal + 1)\(punctuation) "
        } else {
            let bullet = markerText.dropFirst(indent.count).first.map(String.init) ?? "-"
            next += bullet + " "
        }
        if checkbox != nil { next += "[ ] " }
        return ListContinuation(
            replaceRange: NSRange(location: offset, length: 0),
            insertion: "\n" + next
        )
    }

    /// Indents or outdents every list line touched by `lineRange`.
    ///
    /// Note for the app layer: this returns *indentation* edits only.  Changing
    /// nesting changes which ordered list an item belongs to, and the correct
    /// numbering can only be computed from the reparsed result — so apply these
    /// edits, reparse, then run `TidyDocument.plan(rules: [.orderedListNumbers])`
    /// in the same undo group to satisfy §6.4's "renumbering ordered lists
    /// automatically".
    public static func indent(_ doc: ParsedDocument, lineRange: NSRange, outdent: Bool) -> [TextEdit] {
        let firstLine = doc.line(at: max(0, lineRange.location))
        let lastLine = doc.line(at: max(lineRange.location, lineRange.upperBound - 1))
        guard firstLine <= lastLine else { return [] }

        var edits: [TextEdit] = []
        for line in firstLine...lastLine {
            let range = doc.range(ofLine: line)
            let source = doc.substring(range)
            guard !source.isBlankLine else { continue }
            let indent = source.leadingIndent
            let contentOffset = min(range.upperBound, range.location + indent.utf16.count)
            guard enclosingItem(doc, offset: contentOffset) != nil else { continue }
            let width = indentWidth(of: String(source.dropFirst(indent.count)))

            if outdent {
                guard !indent.isEmpty else { continue }
                let removal = indent.hasSuffix("\t") ? 1 : min(width, indent.count)
                guard removal > 0 else { continue }
                edits.append(TextEdit(
                    range: NSRange(location: range.location + indent.utf16.count - removal, length: removal),
                    replacement: "",
                    summary: "Outdent line \(line)"
                ))
            } else {
                edits.append(TextEdit(
                    range: NSRange(location: range.location, length: 0),
                    replacement: String(repeating: " ", count: width),
                    summary: "Indent line \(line)"
                ))
            }
        }
        return edits
    }

    /// One indent step is the width of the line's own marker, so a nested item
    /// lines up under its parent's text rather than at an arbitrary tab stop.
    private static func indentWidth(of line: String) -> Int {
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).first.map({ $0 == "." || $0 == ")" }) == true {
            return digits.count + 2
        }
        if let bullet = line.first, bullet == "-" || bullet == "*" || bullet == "+" { return 2 }
        return 2
    }

    /// Innermost list item at `offset`.  Matching is done against the item's
    /// *lines* rather than its range: cmark ends an empty item at its marker,
    /// so a caret parked after the trailing space of `"  - "` is outside the
    /// item's range but unmistakably inside the item.
    private static func enclosingItem(_ doc: ParsedDocument, offset: Int) -> MDBlock? {
        let text = doc.text as NSString
        var found: MDBlock?
        doc.root.walkPruning { candidate in
            let lastCharacter = max(candidate.range.location, candidate.range.upperBound - 1)
            let end = text.lineEnd(after: lastCharacter)
            let lines = NSRange(
                location: candidate.range.location,
                length: max(candidate.range.length, end - candidate.range.location)
            )
            guard lines.touches(offset: offset) else { return false }
            if case .listItem = candidate.content { found = candidate }
            return true
        }
        return found
    }
}
