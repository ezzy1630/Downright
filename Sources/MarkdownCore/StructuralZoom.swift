import Foundation
import NaturalLanguage

// MARK: - Structural zoom (§5.2)
//
// "The document changes resolution in place."  Levels 1–3 keep headings down to
// a depth; level 4 — the one that matters for agent output — keeps every
// heading, the first sentence of each section, and every concrete artifact
// (code block, table, math, task list): "every claim's headline plus all the
// concrete artifacts, and none of the connective padding."
//
// Ranges are whole lines.  Eliding a partial line would leave the renderer to
// stitch a fragment back together mid-paragraph, and §5.2 wants headings to
// hold their vertical position through the transition, which whole lines make
// trivial.

public enum StructuralZoom {
    public static func plan(_ doc: ParsedDocument, level: ZoomLevel) -> ZoomPlan {
        guard level != .everything, doc.length > 0 else { return .all }
        let map = SourceMap(doc.text)
        var keep: [NSRange] = []

        for heading in doc.headings where heading.level <= level.maxHeadingLevel {
            keep.append(lines(of: heading.range, in: map))
        }

        if level == .skeleton {
            keep.append(contentsOf: skeletonExtras(doc, map: map))
        }
        if let front = doc.frontMatter {
            keep.append(lines(of: front.range, in: map))
        }

        let visible = normalise(keep, limit: map.length)
        return ZoomPlan(visibleRanges: visible, elidedRanges: complement(visible, limit: map.length))
    }

    /// Level 4's additions: the first sentence of each section, and every code
    /// block, table, math block, mermaid diagram and task list in full.
    private static func skeletonExtras(_ doc: ParsedDocument, map: SourceMap) -> [NSRange] {
        var keep: [NSRange] = []
        // Bridged and built once, then reused for every section below: this
        // loop runs once per heading, and a 500-heading document paid both
        // costs 500 times over.
        let text = doc.text as NSString
        let tokenizer = NLTokenizer(unit: .sentence)

        doc.root.walkPruning { block in
            switch block.content {
            case .codeBlock, .table, .mermaid, .mathBlock:
                keep.append(lines(of: block.range, in: map))
                return false
            case .list:
                if containsTask(block) {
                    keep.append(lines(of: block.range, in: map))
                    return false
                }
                return true
            case .document, .blockQuote, .callout, .listItem:
                return true
            default:
                return false
            }
        }

        // One sentence per section, taken from the section's own prose so a
        // code block immediately under a heading is never mistaken for one.
        for (index, heading) in doc.headings.enumerated() {
            let end = index + 1 < doc.headings.count ? doc.headings[index + 1].range.location : doc.length
            let start = heading.range.upperBound
            guard end > start else { continue }
            let body = NSRange(location: start, length: end - start)
            if let sentence = Metrics.firstSentenceRange(in: doc, within: body, text: text, tokenizer: tokenizer) {
                keep.append(lines(of: sentence, in: map))
            }
        }

        // A document that opens without a heading still deserves its lede.
        if let first = doc.headings.first, first.range.location > 0 {
            let lede = NSRange(location: 0, length: first.range.location)
            if let sentence = Metrics.firstSentenceRange(in: doc, within: lede, text: text, tokenizer: tokenizer) {
                keep.append(lines(of: sentence, in: map))
            }
        } else if doc.headings.isEmpty {
            let all = NSRange(location: 0, length: doc.length)
            if let sentence = Metrics.firstSentenceRange(in: doc, within: all, text: text, tokenizer: tokenizer) {
                keep.append(lines(of: sentence, in: map))
            }
        }
        return keep
    }

    private static func containsTask(_ list: MDBlock) -> Bool {
        list.children.contains { child in
            if case .listItem(_, let checkbox) = child.content { return checkbox != nil }
            return false
        }
    }

    /// Expands a range to whole lines, terminators included.
    private static func lines(of range: NSRange, in map: SourceMap) -> NSRange {
        let first = map.line(containing: range.location)
        let last = map.line(containing: max(range.location, range.upperBound - 1))
        let start = map.lineStarts[first]
        let end = map.fullRange(ofLine: last).upperBound
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Ascending, non-overlapping, clamped — the contract `ZoomPlan` states.
    private static func normalise(_ ranges: [NSRange], limit: Int) -> [NSRange] {
        let sorted = ranges
            .filter { $0.length > 0 && $0.location < limit }
            .map { NSRange(location: $0.location, length: min($0.length, limit - $0.location)) }
            .sorted { $0.location < $1.location }
        guard var current = sorted.first else { return [] }
        var out: [NSRange] = []
        for range in sorted.dropFirst() {
            if range.location <= current.upperBound {
                current = current.union(range)
            } else {
                out.append(current)
                current = range
            }
        }
        out.append(current)
        return out
    }

    private static func complement(_ visible: [NSRange], limit: Int) -> [NSRange] {
        var out: [NSRange] = []
        var cursor = 0
        for range in visible {
            if range.location > cursor {
                out.append(NSRange(location: cursor, length: range.location - cursor))
            }
            cursor = max(cursor, range.upperBound)
        }
        if cursor < limit { out.append(NSRange(location: cursor, length: limit - cursor)) }
        return out
    }
}
