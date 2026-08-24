import Foundation
import NaturalLanguage

// MARK: - Plain text extraction
//
// "Words" in §9.6 means words a human reads.  Markers, code, math, raw HTML and
// front matter are all excluded — a 200-line YAML block should not read as
// twenty minutes.  Working from the inline spans rather than from a regex over
// the source is what makes that exact: every marker range is already known.

enum PlainText {
    /// Readable text of one block, markers removed.
    static func of(_ block: MDBlock, in text: NSString) -> String {
        var out = ""
        append(block: block, in: text, to: &out)
        return out
    }

    static func of(spans: [InlineSpan], in text: NSString) -> String {
        var out = ""
        append(spans: spans, in: text, to: &out)
        return out
    }

    private static func append(block: MDBlock, in text: NSString, to out: inout String) {
        switch block.content {
        case .codeBlock, .mermaid, .mathBlock, .htmlBlock, .frontMatter, .thematicBreak:
            return
        case .table(let table):
            for (rIdx, row) in table.rows.enumerated() {
                if rIdx > 0 && !out.isEmpty { out.append(" ") }
                for (cIdx, cell) in row.cells.enumerated() {
                    if cIdx > 0 && !out.isEmpty { out.append(" ") }
                    append(spans: cell.inlines, in: text, to: &out)
                }
            }
            return
        default:
            break
        }
        if !block.inlines.isEmpty {
            append(spans: block.inlines, in: text, to: &out)
            return
        }
        for (index, child) in block.children.enumerated() {
            let beforeCount = out.count
            append(block: child, in: text, to: &out)
            if out.count > beforeCount && index < block.children.count - 1 {
                out.append(" ")
            }
        }
    }

    private static func append(spans: [InlineSpan], in text: NSString, to out: inout String) {
        for span in spans {
            switch span.kind {
            case .text, .pathToken:
                out.append(text.substring(with: span.range))
            case .inlineCode:
                out.append(text.substring(with: span.contentRange))
            case .softBreak, .lineBreak:
                out.append(" ")
            case .inlineHTML, .inlineMath, .footnoteReference:
                continue
            case .wikilink(let target, let label):
                out.append(label ?? target)
            default:
                append(spans: span.children, in: text, to: &out)
            }
        }
    }

    /// Prose within `range`, used for read time and word counts.
    static func prose(in root: MDBlock, range: NSRange, text: NSString) -> String {
        var pieces: [String] = []
        root.walkPruning { block in
            guard block.range.upperBound > range.location, block.range.location < range.upperBound
            else { return false }
            switch block.content {
            case .document, .blockQuote, .callout, .list, .listItem:
                return true
            default:
                let piece = of(block, in: text)
                if !piece.isEmpty { pieces.append(piece) }
                return false
            }
        }
        return pieces.joined(separator: "\n")
    }

    /// Prose per section span, computed in a single tree walk.  `spans` must be
    /// ordered by location and non-overlapping (each heading's own prose, i.e.
    /// subsections excluded).  A block belongs to the section whose span it
    /// overlaps; blocks that overlap none (preamble, the headings themselves)
    /// contribute nothing, matching `prose(in:range:)` exactly.
    static func prosePerSection(in root: MDBlock, spans: [NSRange], text: NSString) -> [String] {
        guard !spans.isEmpty else { return [] }
        var buffers = [String](repeating: "", count: spans.count)

        root.walkPruning { block in
            switch block.content {
            case .document, .blockQuote, .callout, .list, .listItem:
                return true
            default:
                let location = block.range.location
                let upper = block.range.upperBound
                // Largest span whose start precedes the block; the only span that
                // can overlap it, since spans never start mid-block.
                var lo = 0, hi = spans.count - 1, best = -1
                while lo <= hi {
                    let mid = (lo + hi) / 2
                    if spans[mid].location <= location {
                        best = mid
                        lo = mid + 1
                    } else {
                        hi = mid - 1
                    }
                }
                if best >= 0, upper > spans[best].location, location < spans[best].upperBound {
                    let piece = of(block, in: text)
                    if !piece.isEmpty {
                        if buffers[best].isEmpty {
                            buffers[best] = piece
                        } else {
                            buffers[best].append("\n")
                            buffers[best].append(piece)
                        }
                    }
                }
                return false
            }
        }
        return buffers
    }
}

// MARK: - Reading metadata (§9.6)

public enum Metrics {
    /// The median silent-reading rate for prose.  One number, stated once.
    public static let wordsPerMinute = 238.0

    public static func metrics(for text: String) -> ReadingMetrics {
        guard !text.isEmpty else { return .zero }
        let document = MarkdownParser.parse(text, options: .structureOnly)
        return metrics(of: PlainText.prose(
            in: document.root,
            range: NSRange(location: 0, length: document.length),
            text: document.text as NSString
        ))
    }

    /// Parallel to `doc.headings`; each entry covers that section's own prose,
    /// subsections excluded, which is what makes the outline panel's read times
    /// tell you where the bulk of a document actually is (§9.6).
    public static func sectionMetrics(_ doc: ParsedDocument) -> [ReadingMetrics] {
        let text = doc.text as NSString
        let headings = doc.headings
        guard !headings.isEmpty else { return [] }
        var spans: [NSRange] = []
        spans.reserveCapacity(headings.count)
        for (index, heading) in headings.enumerated() {
            let end = index + 1 < headings.count
                ? headings[index + 1].range.location
                : doc.length
            let start = heading.range.upperBound
            spans.append(NSRange(location: start, length: max(0, end - start)))
        }
        return PlainText.prosePerSection(in: doc.root, spans: spans, text: text).map { metrics(of: $0) }
    }

    /// Readable word count for the whole document, excluding code/math/HTML.
    public static func documentWordCount(_ doc: ParsedDocument) -> Int {
        wordCount(PlainText.prose(
            in: doc.root,
            range: NSRange(location: 0, length: doc.length),
            text: doc.text as NSString
        ))
    }

    /// First sentence of the prose in `range`, as a source range.  Used by
    /// structural zoom level 4 (§5.2), where the first sentence of each section
    /// is what survives.
    public static func firstSentenceRange(in doc: ParsedDocument, within range: NSRange) -> NSRange? {
        firstSentenceRange(
            in: doc, within: range,
            text: doc.text as NSString,
            tokenizer: NLTokenizer(unit: .sentence)
        )
    }

    /// The same lookup with the two per-call costs hoisted out.  Structural zoom
    /// asks this question once per heading, and both bridging `doc.text` and
    /// building an `NLTokenizer` are expensive enough that paying them per call
    /// made a level-4 plan quadratic in document size (§5.2).
    static func firstSentenceRange(
        in doc: ParsedDocument,
        within range: NSRange,
        text: NSString,
        tokenizer: NLTokenizer
    ) -> NSRange? {
        guard range.length > 0, range.upperBound <= doc.length else { return nil }
        // Only a leaf text block can contribute a sentence; a code block in the
        // way must not be mistaken for one.
        guard let paragraph = firstProseBlock(in: doc.root, range: range) else { return nil }
        let bounds = NSRange(
            location: max(range.location, paragraph.contentRange.location),
            length: min(range.upperBound, paragraph.contentRange.upperBound)
                - max(range.location, paragraph.contentRange.location)
        )
        guard bounds.length > 0 else { return nil }

        let source = text.substring(with: bounds)
        tokenizer.string = source
        var result: NSRange?
        tokenizer.enumerateTokens(in: source.startIndex..<source.endIndex) { tokenRange, _ in
            let utf16Start = source.utf16.distance(from: source.utf16.startIndex, to: tokenRange.lowerBound)
            let utf16End = source.utf16.distance(from: source.utf16.startIndex, to: tokenRange.upperBound)
            result = NSRange(
                location: bounds.location + utf16Start,
                length: utf16End - utf16Start
            )
            return false
        }
        return result
    }

    private static func firstProseBlock(in root: MDBlock, range: NSRange) -> MDBlock? {
        var found: MDBlock?
        root.walkPruning { block in
            if found != nil { return false }
            guard block.range.upperBound > range.location, block.range.location < range.upperBound
            else { return false }
            switch block.content {
            case .paragraph:
                found = block
                return false
            case .document, .blockQuote, .callout, .list, .listItem:
                return true
            default:
                return false
            }
        }
        return found
    }

    static func metrics(of prose: String) -> ReadingMetrics {
        let words = wordCount(prose)
        return ReadingMetrics(
            words: words,
            characters: prose.count,
            sentences: sentenceCount(prose),
            readMinutes: Double(words) / wordsPerMinute
        )
    }

    public static func wordCount(_ prose: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in prose.unicodeScalars {
            let v = scalar.value
            let isWord: Bool
            if v < 128 {
                isWord = (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || v == 0x27 || v == 0x2D
            } else {
                isWord = scalar == "\u{2019}" || scalar.properties.isAlphabetic || scalar.properties.numericType != nil
            }
            if isWord {
                if !inWord { count += 1; inWord = true }
            } else {
                inWord = false
            }
        }
        return count
    }

    static func sentenceCount(_ prose: String) -> Int {
        guard !prose.isEmpty else { return 0 }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = prose
        var count = 0
        tokenizer.enumerateTokens(in: prose.startIndex..<prose.endIndex) { _, _ in
            count += 1
            return true
        }
        return count
    }
}
