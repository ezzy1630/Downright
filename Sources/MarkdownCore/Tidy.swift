import Foundation

// MARK: - Tidy Document (§9.1)
//
// "Run it on any agent document and it stops looking machine-made."
//
// Every rule produces `TextEdit`s rather than mutating text, because §9.1 shows
// a rendered diff with per-change accept/reject before anything is applied.
// Two invariants the tests pin down:
//
//  * **Idempotence.** Applying the plan and re-planning must produce nothing.
//    A rule that normalises to a form it would then re-normalise is a bug that
//    only shows up as a document that never stops changing.
//  * **No overlaps.** Rules that could contend for the same characters (table
//    pipes vs trailing whitespace, blank lines vs code fences) explicitly skip
//    ranges owned by another rule, rather than relying on `applied(to:)` to
//    drop the loser — that would silently break idempotence.

public enum TidyDocument {
    public static func plan(
        _ doc: ParsedDocument, rules: Set<TidyRule> = Set(TidyRule.allCases)
    ) -> [TextEdit] {
        guard doc.length > 0 else { return [] }
        let context = TidyContext(doc: doc, rules: rules)
        var edits: [TextEdit] = []

        if rules.contains(.headingLevels) { edits += headingLevels(context) }
        if rules.contains(.tablePipes) { edits += tablePipes(context) }
        if rules.contains(.codeFenceLanguages) { edits += codeFenceLanguages(context) }
        if rules.contains(.orderedListNumbers) { edits += orderedListNumbers(context) }
        if rules.contains(.listMarkers) { edits += listMarkers(context) }
        if rules.contains(.trailingWhitespace) { edits += trailingWhitespace(context) }
        if rules.contains(.blankLines) { edits += blankLines(context) }

        return edits
            .filter { $0.range.length > 0 || !$0.replacement.isEmpty }
            .sorted { $0.range.location < $1.range.location }
    }

    // MARK: Rule: heading levels

    /// Agents jump H2 → H4 constantly.  H1 is never touched — it is the
    /// document title and re-levelling it changes what the document *is* — and
    /// a collapsed jump carries down, so H2 → H4 → H5 becomes H2 → H3 → H4
    /// rather than H2 → H3 → H5.
    private static func headingLevels(_ context: TidyContext) -> [TextEdit] {
        var edits: [TextEdit] = []
        var stack: [(original: Int, corrected: Int)] = []

        for heading in context.doc.headings {
            while let top = stack.last, top.original >= heading.level { stack.removeLast() }
            let corrected: Int
            if heading.level == 1 {
                corrected = 1
            } else if let parent = stack.last {
                corrected = min(heading.level, min(6, parent.corrected + 1))
            } else {
                corrected = heading.level
            }
            stack.append((heading.level, corrected))
            guard corrected != heading.level else { continue }

            // Only ATX headings carry a `#` run to rewrite; a setext heading
            // cannot express a jump in the first place.
            let line = context.doc.range(ofLine: context.doc.line(at: heading.range.location))
            let source = context.doc.substring(line)
            let indent = source.leadingIndent
            let hashes = source.dropFirst(indent.count).prefix { $0 == "#" }
            guard hashes.count == heading.level else { continue }

            edits.append(TextEdit(
                range: NSRange(location: line.location + indent.utf16.count, length: hashes.count),
                replacement: String(repeating: "#", count: corrected),
                summary: "H\(heading.level) → H\(corrected): \(heading.title)",
                rule: .headingLevels
            ))
        }
        return edits
    }

    // MARK: Rule: table pipes

    private static func tablePipes(_ context: TidyContext) -> [TextEdit] {
        context.tables.compactMap { block, table in
            let range = TableFormatter.sourceRange(of: table, fallback: block.range)
            let rendered = TableFormatter.render(TableFormatter.model(of: table, in: context.text))
            guard !rendered.isEmpty, rendered != context.text.substring(with: range) else { return nil }
            return TextEdit(
                range: range, replacement: rendered,
                summary: "Align \(table.columnCount)-column table",
                rule: .tablePipes
            )
        }
    }

    // MARK: Rule: code fence languages

    private static func codeFenceLanguages(_ context: TidyContext) -> [TextEdit] {
        var edits: [TextEdit] = []
        context.doc.root.walk { block in
            guard case .codeBlock(let language, let isFenced, let contentRange) = block.content,
                  isFenced, language == nil,
                  let marker = block.markerRange
            else { return }
            let code = context.text.substring(with: contentRange)
            guard let guess = FenceLanguage.guess(from: code) else { return }

            // Insert straight after the fence characters, leaving the rest of
            // the marker (the newline) alone.
            let fence = context.text.substring(with: marker)
            let indent = fence.leadingIndent.utf16.count
            let ticks = fence.dropFirst(fence.leadingIndent.count).prefix { $0 == "`" || $0 == "~" }
            edits.append(TextEdit(
                range: NSRange(location: marker.location + indent + ticks.count, length: 0),
                replacement: guess,
                summary: "Add language hint `\(guess)`",
                rule: .codeFenceLanguages
            ))
        }
        return edits
    }

    // MARK: Rule: ordered list numbers

    private static func orderedListNumbers(_ context: TidyContext) -> [TextEdit] {
        var edits: [TextEdit] = []
        context.doc.root.walk { block in
            guard case .list(let ordered, let start, _, _) = block.content, ordered else { return }
            for (offset, item) in block.children.enumerated() {
                guard case .listItem = item.content, let marker = item.markerRange else { continue }
                let source = context.text.substring(with: marker)
                let indent = source.leadingIndent
                let digits = source.dropFirst(indent.count).prefix { $0.isNumber }
                guard !digits.isEmpty else { continue }
                let expected = String(start + offset)
                guard String(digits) != expected else { continue }
                edits.append(TextEdit(
                    range: NSRange(location: marker.location + indent.utf16.count, length: digits.count),
                    replacement: expected,
                    summary: "Renumber list item \(digits) → \(expected)",
                    rule: .orderedListNumbers
                ))
            }
        }
        return edits
    }

    // MARK: Rule: list markers

    /// Normalises `*` and `+` bullets to `-`.  A mixed document is the tell
    /// that two different generators wrote it.
    private static func listMarkers(_ context: TidyContext) -> [TextEdit] {
        var edits: [TextEdit] = []
        context.doc.root.walk { block in
            guard case .list(let ordered, _, _, _) = block.content, !ordered else { return }
            for item in block.children {
                guard case .listItem = item.content, let marker = item.markerRange else { continue }
                let source = context.text.substring(with: marker)
                let indent = source.leadingIndent
                guard let bullet = source.dropFirst(indent.count).first, bullet != "-",
                      bullet == "*" || bullet == "+"
                else { continue }
                edits.append(TextEdit(
                    range: NSRange(location: marker.location + indent.utf16.count, length: 1),
                    replacement: "-",
                    summary: "Normalise bullet \(bullet) → -",
                    rule: .listMarkers
                ))
            }
        }
        return edits
    }

    // MARK: Rule: trailing whitespace

    /// Strips trailing spaces and tabs, except an exact two-space run on a
    /// non-empty line, which is a deliberate hard line break (§6.4 requires
    /// that behaviour be "preserved exactly as found").
    private static func trailingWhitespace(_ context: TidyContext) -> [TextEdit] {
        var edits: [TextEdit] = []
        for line in 0..<context.map.lineCount {
            let range = context.map.contentRange(ofLine: line)
            guard range.length > 0, !context.isProtected(range) else { continue }
            let source = context.map.string(ofLine: line)
            let trailing = source.reversed().prefix { $0 == " " || $0 == "\t" }
            guard !trailing.isEmpty else { continue }
            // A whitespace-only blank line inside a run `.blankLines` collapses
            // is that rule's region; trimming it here overlaps the collapse and
            // the loser is dropped silently.
            if context.trailingWhitespaceOwnedByBlankLines(line) { continue }
            let keptBreak = trailing.count == 2 && trailing.allSatisfy { $0 == " " }
                && trailing.count < source.count
            guard !keptBreak else { continue }
            edits.append(TextEdit(
                range: NSRange(
                    location: range.upperBound - trailing.count,
                    length: trailing.count
                ),
                replacement: "",
                summary: "Trim trailing whitespace on line \(line + 1)",
                rule: .trailingWhitespace
            ))
        }
        return edits
    }

    // MARK: Rule: blank lines

    /// Collapses a run of two or more blank lines to one.
    private static func blankLines(_ context: TidyContext) -> [TextEdit] {
        var edits: [TextEdit] = []
        var line = 0
        while line < context.map.lineCount {
            guard context.map.string(ofLine: line).isBlankLine,
                  !context.isProtected(context.map.fullRange(ofLine: line))
            else { line += 1; continue }

            var last = line
            while last + 1 < context.map.lineCount,
                  context.map.string(ofLine: last + 1).isBlankLine,
                  !context.isProtected(context.map.fullRange(ofLine: last + 1)) {
                last += 1
            }
            // The final "line" of a file ending in a newline is an artefact of
            // the index, not a blank line the user typed.
            let lastIsVirtual = last == context.map.lineCount - 1
                && context.map.contentRange(ofLine: last).length == 0
            let effectiveLast = lastIsVirtual ? last - 1 : last

            if effectiveLast > line {
                let start = context.map.lineStarts[line]
                let end = context.map.fullRange(ofLine: effectiveLast).upperBound
                edits.append(TextEdit(
                    range: NSRange(location: start, length: max(0, end - start)),
                    replacement: "\n",
                    summary: "Collapse \(effectiveLast - line + 1) blank lines",
                    rule: .blankLines
                ))
            }
            line = last + 1
        }
        return edits
    }
}

// MARK: - Shared analysis

/// Precomputes what every rule needs: the tables, and the ranges other rules
/// must not touch.
struct TidyContext {
    let doc: ParsedDocument
    let map: SourceMap
    let text: NSString
    /// The rules currently being planned, so a rule that would contend with
    /// another (trailing whitespace vs blank lines on a whitespace-only blank
    /// run) can defer to the one that owns the region instead of emitting an
    /// overlapping edit that `applied(to:)` drops silently.
    let rules: Set<TidyRule>
    let tables: [(block: MDBlock, table: TableData)]
    /// Code, math, HTML, front matter and table source — regions where
    /// whitespace and blank lines are content, not formatting.
    private let protectedRanges: [NSRange]

    init(doc: ParsedDocument, rules: Set<TidyRule>) {
        self.doc = doc
        self.map = SourceMap(doc.text)
        self.text = doc.text as NSString
        self.rules = rules

        var tables: [(MDBlock, TableData)] = []
        var protected: [NSRange] = []
        doc.root.walk { block in
            switch block.content {
            case .table(let table):
                tables.append((block, table))
                protected.append(TableFormatter.sourceRange(of: table, fallback: block.range))
            case .codeBlock, .mermaid, .mathBlock, .htmlBlock, .frontMatter:
                protected.append(block.range)
            default:
                break
            }
        }
        self.tables = tables
        self.protectedRanges = protected.sorted { $0.location < $1.location }
    }

    func isProtected(_ range: NSRange) -> Bool {
        protectedRanges.contains { $0.location < range.upperBound && range.location < $0.upperBound }
    }

    /// True when a whitespace-only line belongs to a run of two or more blank
    /// lines that `.blankLines` will collapse away.  Collapsing the run removes
    /// the whitespace with it, so a trailing-whitespace edit on this line would
    /// overlap the collapse and be dropped silently (§9.1's "no overlaps").
    /// A lone blank line is not owned by `.blankLines` (it is never collapsed),
    /// so trailing whitespace there stays this rule's job.
    func trailingWhitespaceOwnedByBlankLines(_ line: Int) -> Bool {
        guard rules.contains(.blankLines), map.string(ofLine: line).isBlankLine else { return false }
        let previous = line - 1
        let next = line + 1
        let previousBlank = previous >= 0
            && map.string(ofLine: previous).isBlankLine
            && !isProtected(map.fullRange(ofLine: previous))
        let nextBlank = next < map.lineCount
            && map.string(ofLine: next).isBlankLine
            && !isProtected(map.fullRange(ofLine: next))
        return previousBlank || nextBlank
    }
}
