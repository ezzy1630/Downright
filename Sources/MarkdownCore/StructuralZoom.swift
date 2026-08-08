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
    /// Semantic navigation summary for a section. Markdown markers are removed,
    /// inline math becomes a readable placeholder, and two sentences provide
    /// enough context to judge a jump without turning the preview into a reader.
    public static func sectionPreview(_ doc: ParsedDocument, headingIndex: Int) -> String? {
        guard doc.headings.indices.contains(headingIndex) else { return nil }
        let heading = doc.headings[headingIndex]
        let end = headingIndex + 1 < doc.headings.count
            ? doc.headings[headingIndex + 1].range.location
            : doc.length
        let start = heading.range.upperBound
        guard end > start else { return nil }
        let range = NSRange(location: start, length: end - start)
        let prose = previewProse(in: doc, range: range)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !prose.isEmpty else { return artifactSummary(in: doc, range: range) }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = prose
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: prose.startIndex..<prose.endIndex) { token, _ in
            sentences.append(String(prose[token]).trimmingCharacters(in: .whitespacesAndNewlines))
            return sentences.count < 2 && sentences.joined(separator: " ").count < 220
        }
        let summary = sentences.joined(separator: " ")
        return summary.count > 260 ? String(summary.prefix(257)) + "…" : summary
    }

    private static func artifactSummary(in doc: ParsedDocument, range: NSRange) -> String? {
        var codeLanguages: [String] = []
        var codeCount = 0
        var tableCount = 0
        var mathCount = 0
        var diagramCount = 0
        var taskListCount = 0
        doc.root.walkPruning { block in
            guard block.range.upperBound > range.location,
                  block.range.location < range.upperBound
            else { return false }
            switch block.content {
            case .document, .blockQuote, .callout, .listItem:
                return true
            case .list:
                if containsTask(block) { taskListCount += 1; return false }
                return true
            case .codeBlock(let language, _, _):
                codeCount += 1
                if let language, !language.isEmpty,
                   !codeLanguages.contains(where: { $0.caseInsensitiveCompare(language) == .orderedSame }) {
                    codeLanguages.append(language.capitalized)
                }
                return false
            case .table:
                tableCount += 1
                return false
            case .mathBlock:
                mathCount += 1
                return false
            case .mermaid:
                diagramCount += 1
                return false
            default:
                return false
            }
        }

        var parts: [String] = []
        if codeCount > 0 {
            let languages = codeLanguages.prefix(3).joined(separator: ", ")
            parts.append("\(codeCount) code \(codeCount == 1 ? "block" : "blocks")"
                + (languages.isEmpty ? "" : " · \(languages)"))
        }
        if tableCount > 0 { parts.append("\(tableCount) \(tableCount == 1 ? "table" : "tables")") }
        if mathCount > 0 { parts.append("\(mathCount) math \(mathCount == 1 ? "block" : "blocks")") }
        if diagramCount > 0 { parts.append("\(diagramCount) \(diagramCount == 1 ? "diagram" : "diagrams")") }
        if taskListCount > 0 { parts.append("\(taskListCount) task \(taskListCount == 1 ? "list" : "lists")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func previewProse(in doc: ParsedDocument, range: NSRange) -> String {
        let source = doc.text as NSString
        var pieces: [String] = []
        doc.root.walkPruning { block in
            guard block.range.upperBound > range.location,
                  block.range.location < range.upperBound
            else { return false }
            switch block.content {
            case .document, .blockQuote, .callout, .list, .listItem:
                return true
            case .paragraph:
                let text = previewText(block.inlines, source: source)
                if !text.isEmpty { pieces.append(text) }
                return false
            default:
                return false
            }
        }
        return pieces.joined(separator: " ")
    }

    private static func previewText(_ spans: [InlineSpan], source: NSString) -> String {
        spans.map { span in
            switch span.kind {
            case .text, .pathToken:
                return source.substring(with: span.range)
            case .inlineCode:
                return source.substring(with: span.contentRange)
            case .softBreak, .lineBreak:
                return " "
            case .inlineMath:
                return "a formula"
            case .wikilink(let target, let label):
                return label ?? target
            case .image(_, let alt):
                return alt.isEmpty ? "image" : alt
            case .footnoteReference, .inlineHTML:
                return ""
            case .autolink(let destination):
                return destination
            default:
                return previewText(span.children, source: source)
            }
        }.joined()
    }

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
