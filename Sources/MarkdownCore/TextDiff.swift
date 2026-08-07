import Foundation

// MARK: - Text diff (§8.1)
//
// "Changed words inside a modified paragraph are highlighted in the rendered
// prose — not as +/- source lines."  That is why the output is block-shaped
// rather than line-shaped, and why a `.modified` hunk carries `wordRanges`:
// the app needs to know which *words* of the new text to mark, not which lines
// were rewritten.
//
// Deletions and insertions that touch each other are merged into a single
// `.modified` hunk, because a paragraph the agent rewrote reads as one change,
// not as a delete next to an insert.

public enum TextDiff {
    public static func hunks(old: String, new: String) -> [ChangeHunk] {
        if old == new { return [] }
        let oldNS = old as NSString
        let newNS = new as NSString
        let oldLines = lines(of: oldNS)
        let newLines = lines(of: newNS)

        guard let script = Myers.diff(
            oldLines.map { FNV.hash(oldNS, range: $0) },
            newLines.map { FNV.hash(newNS, range: $0) }
        ) else {
            // Beyond the distance cap the documents have nothing in common;
            // one whole-document hunk is both true and instant.
            return [ChangeHunk(
                kind: .modified,
                newRange: NSRange(location: 0, length: newNS.length),
                oldRange: NSRange(location: 0, length: oldNS.length),
                wordRanges: []
            )]
        }

        var hunks: [ChangeHunk] = []
        var deleted: [NSRange] = []
        var inserted: [NSRange] = []
        var oldCursor = 0
        var newCursor = 0

        func flush() {
            defer { deleted.removeAll(keepingCapacity: true); inserted.removeAll(keepingCapacity: true) }
            guard !deleted.isEmpty || !inserted.isEmpty else { return }
            let oldRange = deleted.isEmpty
                ? NSRange(location: oldCursor, length: 0)
                : span(deleted)
            let newRange = inserted.isEmpty
                ? NSRange(location: newCursor, length: 0)
                : span(inserted)

            if deleted.isEmpty {
                // Brand-new prose is the *strongest* signal on the page, so it
                // gets the same word-level highlight a rewritten paragraph
                // gets.  Leaving `wordRanges` empty gave three new paragraphs a
                // hairline in the margin while a one-word edit got a filled
                // background — exactly backwards.
                hunks.append(ChangeHunk(
                    kind: .inserted, newRange: newRange, oldRange: oldRange,
                    wordRanges: insertedWords(in: newNS, span: newRange)
                ))
            } else if inserted.isEmpty {
                hunks.append(ChangeHunk(kind: .deleted, newRange: newRange, oldRange: oldRange))
            } else {
                hunks.append(ChangeHunk(
                    kind: .modified, newRange: newRange, oldRange: oldRange,
                    wordRanges: changedWords(
                        old: oldNS.substring(with: oldRange), oldRange: oldRange,
                        new: newNS.substring(with: newRange), newRange: newRange
                    )
                ))
            }
        }

        for step in script {
            switch step {
            case .equal(let oldIndex, let newIndex):
                flush()
                oldCursor = oldLines[oldIndex].upperBound
                newCursor = newLines[newIndex].upperBound
            case .delete(let index):
                deleted.append(oldLines[index])
                oldCursor = oldLines[index].location
            case .insert(let index):
                inserted.append(newLines[index])
                newCursor = newLines[index].location
            }
        }
        flush()
        return hunks
    }

    // MARK: Deletions

    /// A non-degenerate range in the new text for a hunk that has no new text.
    ///
    /// A pure deletion's `newRange` is empty by definition — the bytes are
    /// gone — but an empty range is unrenderable: the overlay clamps it away
    /// and the density band comes out zero-height, so "the agent replaced a
    /// section you wanted" is the one change the reader could not see.  Anchor
    /// it on the single character at the join point (the character *after* the
    /// join, or the last character of the document when the deletion ran to the
    /// end) so the UI has a caret position and a row rectangle to work from.
    ///
    /// The removed bytes themselves live in `oldRange` of the old text; the
    /// caller pairs the two to expand the caret into a ghost block.
    public static func anchorRange(for hunk: ChangeHunk, inNewTextOfLength length: Int) -> NSRange {
        if hunk.newRange.length > 0 { return hunk.newRange }
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let location = min(max(0, hunk.newRange.location), length)
        if location < length { return NSRange(location: location, length: 1) }
        return NSRange(location: length - 1, length: 1)
    }

    // MARK: Line and word tokenisation

    /// Lines including their terminators, so a hunk's range covers whole lines
    /// and re-decoration never lands mid-line.
    static func lines(of text: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var index = 0
        while index < text.length {
            let end = text.lineEnd(after: index)
            out.append(NSRange(location: index, length: end - index))
            index = end
        }
        return out
    }

    private static func span(_ ranges: [NSRange]) -> NSRange {
        guard let first = ranges.first, let last = ranges.last else {
            return NSRange(location: 0, length: 0)
        }
        return NSRange(location: first.location, length: last.upperBound - first.location)
    }

    /// Word-level ranges *within the new text* that differ from the old — the
    /// highlight set for §8.1's changed-words-in-rendered-prose.
    static func changedWords(
        old: String, oldRange: NSRange, new: String, newRange: NSRange
    ) -> [NSRange] {
        let oldWords = words(in: old as NSString)
        let newWords = words(in: new as NSString)
        let oldNS = old as NSString
        let newNS = new as NSString

        guard let script = Myers.diff(
            oldWords.map { FNV.hash(oldNS, range: $0) },
            newWords.map { FNV.hash(newNS, range: $0) },
            maxDistance: 2048
        ) else {
            return [newRange]
        }

        var out: [NSRange] = []
        for case .insert(let index) in script {
            let word = newWords[index]
            out.append(NSRange(location: newRange.location + word.location, length: word.length))
        }
        return merge(out)
    }

    /// Every word of an inserted span, in coordinates of the whole new text.
    /// Word-split rather than one flat range so the highlight skips newlines
    /// and punctuation; a background colour painted over a line terminator
    /// draws a full-width block that reads as a bug.
    static func insertedWords(in text: NSString, span: NSRange) -> [NSRange] {
        guard span.length > 0 else { return [] }
        let body = text.substring(with: span) as NSString
        return merge(words(in: body).map {
            NSRange(location: span.location + $0.location, length: $0.length)
        })
    }

    /// Words, punctuation excluded — matching on words rather than on runs of
    /// non-space keeps "the cat." vs "the cat!" to a one-token change.
    static func words(in text: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var index = 0
        var start = -1
        while index < text.length {
            let ch = text.character(at: index)
            let isWord = (ch >= 0x30 && ch <= 0x39)
                || (ch >= 0x41 && ch <= 0x5A)
                || (ch >= 0x61 && ch <= 0x7A)
                || ch >= 0x80
                || ch == 0x27 || ch == 0x2D || ch == 0x5F
            if isWord {
                if start < 0 { start = index }
            } else if start >= 0 {
                out.append(NSRange(location: start, length: index - start))
                start = -1
            }
            index += 1
        }
        if start >= 0 { out.append(NSRange(location: start, length: text.length - start)) }
        return out
    }

    /// Adjacent or near-adjacent word ranges become one highlight; a run of
    /// three rewritten words should not draw three separate marks.
    private static func merge(_ ranges: [NSRange]) -> [NSRange] {
        guard ranges.count > 1 else { return ranges }
        var out: [NSRange] = [ranges[0]]
        for range in ranges.dropFirst() {
            let last = out[out.count - 1]
            if range.location <= last.upperBound + 1 {
                out[out.count - 1] = last.union(range)
            } else {
                out.append(range)
            }
        }
        return out
    }
}
