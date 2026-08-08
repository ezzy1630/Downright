import Foundation
import Markdown

// MARK: - Parsing (§4)
//
// `file bytes → NSTextStorage → swift-markdown parse → extension pass →
// extended AST`.  This file owns the middle three arrows.
//
// Two decisions are worth stating up front because everything else follows
// from them:
//
//  * Front matter is stripped *before* cmark runs.  `---` on line 1 followed by
//    `title: X` parses as a thematic break plus a setext H2 — see the fixtures
//    in `ParserTests` — which is both wrong and would poison every range after
//    it.  The body is parsed on its own and line numbers are shifted back.
//  * `.disableSmartOpts` is mandatory, not a preference.  cmark's smart
//    punctuation rewrites quotes and dashes *in the AST*, and §3.1 says the
//    bytes are the truth.  §6.4 independently wants typographic substitution
//    off by default because "agents and code hate smart quotes".

public enum MarkdownParser {
    public static func parse(_ text: String, options: ParseOptions = .default) -> ParsedDocument {
        let map = SourceMap(text)
        guard map.length > 0 else { return .empty }
        let runExtensions = map.length <= options.extensionPassLimit

        let frontMatter = options.detectFrontMatter ? FrontMatterScanner.scan(map) : nil
        let bodyStart = frontMatter?.range.upperBound ?? 0
        let lineOffset = frontMatter == nil ? 0 : map.line(containing: bodyStart)
        let body = bodyStart == 0 ? text : map.text.substring(from: bodyStart)

        let document = Document(parsing: body, options: [.disableSmartOpts])
        let scan = SourceScanner(map: map)

        var builder = BlockBuilder(
            map: map,
            lineOffset: lineOffset,
            options: options,
            runExtensions: runExtensions,
            footnoteIdentifiers: Set(scan.footnoteDefinitions.map(\.identifier))
        )

        var children = document.children.compactMap { builder.block(for: $0, depth: 1, quoteDepth: 0) }
        if let frontMatter {
            children.insert(builder.frontMatterBlock(frontMatter), at: 0)
        }
        builder.attachFootnoteDefinitions(&children, definitions: scan.footnoteDefinitions)

        let root = MDBlock(
            content: .document,
            range: NSRange(location: 0, length: map.length),
            contentRange: NSRange(location: 0, length: map.length),
            children: children,
            depth: 0
        )
        BlockIdentifier.assign(root)
        SubtreeHasher.hash(root, in: map.text)

        let derived = DerivedStructures(root: root, map: map)
        return ParsedDocument(
            text: text,
            length: map.length,
            root: root,
            frontMatter: frontMatter,
            headings: derived.headings,
            tasks: derived.tasks,
            pathTokens: builder.inlines.pathTokens,
            footnotes: derived.footnotes,
            linkReferences: scan.linkReferences,
            lineStarts: map.lineStarts
        )
    }
}

// MARK: - Block construction

struct BlockBuilder {
    let map: SourceMap
    let lineOffset: Int
    let options: ParseOptions
    let runExtensions: Bool
    var inlines: InlineBuilder

    init(
        map: SourceMap,
        lineOffset: Int,
        options: ParseOptions,
        runExtensions: Bool,
        footnoteIdentifiers: Set<String>
    ) {
        self.map = map
        self.lineOffset = lineOffset
        self.options = options
        self.runExtensions = runExtensions
        self.inlines = InlineBuilder(
            map: map, lineOffset: lineOffset, options: options,
            runExtensions: runExtensions, footnoteIdentifiers: footnoteIdentifiers
        )
    }

    private var text: NSString { map.text }

    mutating func block(for markup: Markup, depth: Int, quoteDepth: Int) -> MDBlock? {
        guard var range = map.range(markup.range, lineOffset: lineOffset) else { return nil }

        switch markup {
        case let heading as Heading:
            return headingBlock(heading, range: &range, depth: depth, quoteDepth: quoteDepth)

        case is Paragraph:
            return paragraphBlock(markup, range: range, depth: depth, quoteDepth: quoteDepth)

        case let quote as BlockQuote:
            return quoteBlock(quote, range: range, depth: depth, quoteDepth: quoteDepth)

        case let list as UnorderedList:
            return listBlock(list, ordered: false, start: 1, range: range, depth: depth, quoteDepth: quoteDepth)

        case let list as OrderedList:
            return listBlock(
                list, ordered: true, start: Int(list.startIndex),
                range: range, depth: depth, quoteDepth: quoteDepth
            )

        case let item as ListItem:
            return listItemBlock(item, range: range, depth: depth, quoteDepth: quoteDepth)

        case let code as CodeBlock:
            return codeBlock(code, range: range, depth: depth, quoteDepth: quoteDepth)

        case let table as Markdown.Table:
            return tableBlock(table, range: range, depth: depth, quoteDepth: quoteDepth)

        case is ThematicBreak:
            return MDBlock(
                content: .thematicBreak, range: range,
                contentRange: NSRange(location: range.upperBound, length: 0),
                markerRange: range, depth: depth, quoteDepth: quoteDepth
            )

        case is HTMLBlock:
            return MDBlock(
                content: .htmlBlock, range: range, contentRange: range,
                depth: depth, quoteDepth: quoteDepth
            )

        default:
            // Block directives, doxygen commands and custom blocks: keep their
            // characters covered by *something* rather than dropping them.
            let children = markup.children.compactMap {
                block(for: $0, depth: depth + 1, quoteDepth: quoteDepth)
            }
            if children.isEmpty {
                return MDBlock(
                    content: .paragraph, range: range, contentRange: range,
                    inlines: inlines.spans(for: markup, bounds: range),
                    depth: depth, quoteDepth: quoteDepth
                )
            }
            return MDBlock(
                content: .blockQuote, range: range, contentRange: range,
                children: children, depth: depth, quoteDepth: quoteDepth
            )
        }
    }

    // MARK: Leaf text blocks

    private mutating func headingBlock(
        _ heading: Heading, range: inout NSRange, depth: Int, quoteDepth: Int
    ) -> MDBlock {
        let childRanges = heading.children.compactMap { map.range($0.range, lineOffset: lineOffset) }
        let firstChild = childRanges.first
        let lastChild = childRanges.last

        let startLine = map.line(containing: range.location)
        let endLine = map.line(containing: max(range.location, range.upperBound - 1))
        let isSetext = endLine > startLine

        if isSetext {
            let underline = map.contentRange(ofLine: endLine)
            let content = NSRange(
                location: range.location,
                length: max(0, (lastChild?.upperBound ?? underline.location) - range.location)
            )
            return MDBlock(
                content: .heading(level: heading.level), range: range, contentRange: content,
                trailingMarkerRange: underline,
                inlines: inlines.spans(for: heading, bounds: content),
                depth: depth, quoteDepth: quoteDepth
            )
        }

        // cmark ends an ATX heading's range before a closing `#` sequence.
        // Extend to the end of the line so the closing run is covered and can
        // be hidden with the opening one (§6.2).
        let lineEnd = map.contentRange(ofLine: startLine).upperBound
        var trailing: NSRange?
        if lineEnd > range.upperBound {
            trailing = NSRange(location: range.upperBound, length: lineEnd - range.upperBound)
            range = NSRange(location: range.location, length: lineEnd - range.location)
        }
        let marker = firstChild.map {
            NSRange(location: range.location, length: max(0, $0.location - range.location))
        } ?? range
        let content = firstChild.map { first -> NSRange in
            let upper = lastChild?.upperBound ?? first.upperBound
            return NSRange(location: first.location, length: max(0, upper - first.location))
        } ?? NSRange(location: range.upperBound, length: 0)

        return MDBlock(
            content: .heading(level: heading.level), range: range, contentRange: content,
            markerRange: marker.length > 0 ? marker : nil, trailingMarkerRange: trailing,
            inlines: inlines.spans(for: heading, bounds: content),
            depth: depth, quoteDepth: quoteDepth
        )
    }

    private mutating func paragraphBlock(
        _ markup: Markup, range: NSRange, depth: Int, quoteDepth: Int
    ) -> MDBlock {
        // A paragraph that is nothing but `$$…$$` or `\[…\]` is a display
        // formula, not prose (§4.1).
        if runExtensions, options.detectMath,
           let block = MathScanner.wholeBlock(in: text, range: range) {
            return MDBlock(
                content: .mathBlock(latexRange: block.contentRange),
                range: range, contentRange: block.contentRange,
                markerRange: NSRange(
                    location: block.range.location,
                    length: block.contentRange.location - block.range.location
                ),
                trailingMarkerRange: NSRange(
                    location: block.contentRange.upperBound,
                    length: block.range.upperBound - block.contentRange.upperBound
                ),
                depth: depth, quoteDepth: quoteDepth
            )
        }
        return MDBlock(
            content: .paragraph, range: range, contentRange: range,
            inlines: inlines.spans(for: markup, bounds: range),
            depth: depth, quoteDepth: quoteDepth
        )
    }

    // MARK: Containers

    private mutating func quoteBlock(
        _ quote: BlockQuote, range: NSRange, depth: Int, quoteDepth: Int
    ) -> MDBlock {
        var children = quote.children.compactMap {
            block(for: $0, depth: depth + 1, quoteDepth: quoteDepth + 1)
        }
        let firstChild = children.first?.range
        var marker = firstChild.map {
            NSRange(location: range.location, length: max(0, $0.location - range.location))
        }

        var content: BlockContent = .blockQuote
        if runExtensions, options.detectCallouts,
           let callout = CalloutScanner.scan(map, quoteRange: range) {
            content = .callout(kind: callout.kind, title: callout.title)
            marker = callout.markerRange
            trimLeading(&children, to: callout.markerRange.upperBound)
        }

        let contentStart = children.first?.range.location ?? range.upperBound
        return MDBlock(
            content: content, range: range,
            contentRange: NSRange(
                location: contentStart, length: max(0, range.upperBound - contentStart)
            ),
            markerRange: marker.flatMap { $0.length > 0 ? $0 : nil },
            children: children, depth: depth, quoteDepth: quoteDepth
        )
    }

    /// Moves a callout's first child past the `> [!NOTE] Title` marker so the
    /// marker never renders as body text.
    private func trimLeading(_ children: inout [MDBlock], to offset: Int) {
        guard let first = children.first, first.range.location < offset else { return }
        if first.range.upperBound <= offset {
            children.removeFirst()
            return
        }
        first.range = NSRange(location: offset, length: first.range.upperBound - offset)
        first.contentRange = NSRange(
            location: max(offset, first.contentRange.location),
            length: max(0, first.contentRange.upperBound - max(offset, first.contentRange.location))
        )
        first.inlines = InlineSpan.clipLeading(first.inlines, to: offset)
    }

    private mutating func listBlock(
        _ list: Markup, ordered: Bool, start: Int, range: NSRange, depth: Int, quoteDepth: Int
    ) -> MDBlock {
        let children = list.children.compactMap {
            block(for: $0, depth: depth + 1, quoteDepth: quoteDepth)
        }
        let marker = markerStyle(at: range.location, ordered: ordered)
        let tight = isTight(children)
        return MDBlock(
            content: .list(ordered: ordered, start: start, tight: tight, marker: marker),
            range: range, contentRange: range, children: children,
            depth: depth, quoteDepth: quoteDepth
        )
    }

    private mutating func listItemBlock(
        _ item: ListItem, range: NSRange, depth: Int, quoteDepth: Int
    ) -> MDBlock {
        let children = item.children.compactMap {
            block(for: $0, depth: depth + 1, quoteDepth: quoteDepth)
        }
        // The marker is everything between the item's start and its content:
        // `- `, `1. `, `- [ ] ` all fall out of the same rule (§6.1a).
        let contentStart = children.first?.range.location ?? range.upperBound
        let marker = NSRange(location: range.location, length: max(0, contentStart - range.location))

        var checkbox: Checkbox?
        if item.checkbox != nil, let markRange = checkboxMarkRange(in: marker) {
            checkbox = Checkbox(
                isChecked: text.substring(with: markRange).trimmingCharacters(in: .whitespaces) != "",
                markRange: markRange
            )
        }
        return MDBlock(
            content: .listItem(ordinal: ordinal(at: range.location), checkbox: checkbox),
            range: range,
            contentRange: NSRange(
                location: contentStart, length: max(0, range.upperBound - contentStart)
            ),
            markerRange: marker.length > 0 ? marker : nil,
            children: children, depth: depth, quoteDepth: quoteDepth
        )
    }

    /// A list is tight when no blank line separates its items and no item holds
    /// more than one block.  cmark folds the blank line into the preceding
    /// item's range, so looking at the text spanning two items finds it.
    private func isTight(_ children: [MDBlock]) -> Bool {
        for index in children.indices.dropFirst() {
            let start = children[index - 1].range.location
            let span = NSRange(location: start, length: max(0, children[index].range.location - start))
            // Only the two trailing UTF-16 units decide; avoid a substring.
            let end = span.upperBound
            if end >= 2, text.character(at: end - 1) == 0x0A, text.character(at: end - 2) == 0x0A { return false }
        }
        // CommonMark: a list is loose when any item directly contains two
        // block-level elements, not only when a single item happens to.
        if children.contains(where: { $0.children.count > 1 }) { return false }
        return true
    }

    private func markerStyle(at offset: Int, ordered: Bool) -> ListMarkerStyle {
        var i = offset
        while i < text.length {
            let ch = text.character(at: i)
            if ordered {
                if ch == 0x2E { return .period }
                if ch == 0x29 { return .paren }
                if ch < 0x30 || ch > 0x39 { break }
            } else {
                switch ch {
                case 0x2D: return .dash
                case 0x2A: return .asterisk
                case 0x2B: return .plus
                default: break
                }
                if ch != 0x20 && ch != 0x09 { break }
            }
            i += 1
        }
        return ordered ? .period : .dash
    }

    private func ordinal(at offset: Int) -> Int? {
        var i = offset
        var value = 0
        var sawDigit = false
        while i < text.length {
            let ch = text.character(at: i)
            guard ch >= 0x30, ch <= 0x39 else { break }
            sawDigit = true
            let digit = Int(ch - 0x30)
            if value > (Int.max - digit) / 10 { return nil }
            value = value * 10 + digit
            i += 1
        }
        return sawDigit ? value : nil
    }

    /// Range of the single character between the brackets of `- [x] `, so a
    /// toggle stays a one-character replacement (`Checkbox.markRange`).
    private func checkboxMarkRange(in marker: NSRange) -> NSRange? {
        var i = marker.location
        while i + 2 < marker.upperBound {
            if text.character(at: i) == 0x5B, text.character(at: i + 2) == 0x5D {
                return NSRange(location: i + 1, length: 1)
            }
            i += 1
        }
        return nil
    }

    // MARK: Code, math and diagrams

    private func codeBlock(
        _ code: CodeBlock, range: NSRange, depth: Int, quoteDepth: Int
    ) -> MDBlock {
        let startLine = map.line(containing: range.location)
        let firstLine = map.string(ofLine: startLine)
        let fenceCharacters = Self.fencePrefix(of: firstLine)
        let isFenced = fenceCharacters.hasPrefix("```") || fenceCharacters.hasPrefix("~~~")

        var content = range
        var marker: NSRange?
        var trailing: NSRange?
        if isFenced {
            let openEnd = map.fullRange(ofLine: startLine).upperBound
            marker = NSRange(location: range.location, length: max(0, openEnd - range.location))
            let endLine = map.line(containing: max(range.location, range.upperBound - 1))
            let closeStart = endLine > startLine ? map.lineStarts[endLine] : range.upperBound
            // A closing fence must match the opening fence's character, not a
            // mixture of both, or a `~~~` code block could be terminated by a
            // backtick fence and vice versa.
            let fenceChar: Character = fenceCharacters.hasPrefix("~~~") ? "~" : "`"
            let closeLine = Self.fencePrefix(of: map.string(ofLine: endLine))
            let hasClosingFence = endLine > startLine
                && !closeLine.isEmpty
                && closeLine.allSatisfy { $0 == fenceChar }
            let contentEnd = hasClosingFence ? closeStart : range.upperBound
            content = NSRange(location: openEnd, length: max(0, contentEnd - openEnd))
            if hasClosingFence {
                trailing = NSRange(location: contentEnd, length: max(0, range.upperBound - contentEnd))
            }
        }

        let language = code.language?.trimmingCharacters(in: .whitespaces)
        let content_ = content
        switch FenceLanguage.kind(for: language) {
        case .mermaid where runExtensions && options.detectMermaid:
            return MDBlock(
                content: .mermaid(sourceRange: content_), range: range, contentRange: content_,
                markerRange: marker, trailingMarkerRange: trailing, depth: depth, quoteDepth: quoteDepth
            )
        case .math where runExtensions && options.detectMath:
            return MDBlock(
                content: .mathBlock(latexRange: content_), range: range, contentRange: content_,
                markerRange: marker, trailingMarkerRange: trailing, depth: depth, quoteDepth: quoteDepth
            )
        default:
            return MDBlock(
                content: .codeBlock(
                    language: language.flatMap { $0.isEmpty ? nil : $0 },
                    isFenced: isFenced,
                    contentRange: content_
                ),
                range: range, contentRange: content_,
                markerRange: marker, trailingMarkerRange: trailing, depth: depth, quoteDepth: quoteDepth
            )
        }
    }

    /// The fence-visible portion of a code line: leading whitespace and any
    /// blockquote `>` markers stripped.  A fence nested inside a quote
    /// (`> ````) otherwise reads as an indented block — the raw line begins
    /// with `>`, so plain whitespace trimming can never reach the fence, and
    /// the block loses its marker ranges and is marked `isFenced: false` even
    /// though cmark parsed a real fence with a language.
    private static func fencePrefix(of line: String) -> String {
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == " " || character == "\t" || character == ">" {
                index = line.index(after: index)
            } else {
                break
            }
        }
        return String(line[index...])
    }

    // MARK: Tables

    private mutating func tableBlock(
        _ table: Markdown.Table, range: NSRange, depth: Int, quoteDepth: Int
    ) -> MDBlock {
        var rows: [TableRow] = []
        var headEnd = range.location

        for child in table.children {
            switch child {
            case let head as Markdown.Table.Head:
                guard let headRange = map.range(head.range, lineOffset: lineOffset) else { continue }
                headEnd = headRange.upperBound
                rows.append(TableRow(range: headRange, cells: cells(of: head), isHeader: true))
            case let body as Markdown.Table.Body:
                for case let row as Markdown.Table.Row in body.children {
                    guard let rowRange = map.range(row.range, lineOffset: lineOffset) else { continue }
                    rows.append(TableRow(range: rowRange, cells: cells(of: row), isHeader: false))
                }
            default:
                continue
            }
        }

        // cmark models the delimiter row as alignment metadata rather than a
        // node, but the editor has to rewrite it when alignment changes (§6.3),
        // so recover its range from the line after the header.
        let delimiterLine = map.line(containing: max(range.location, headEnd - 1)) + 1
        let delimiterRange = delimiterLine < map.lineCount
            ? map.contentRange(ofLine: delimiterLine)
            : NSRange(location: headEnd, length: 0)

        let alignments = table.columnAlignments.map { alignment -> TableAlignment in
            switch alignment {
            case .left: return .left
            case .center: return .center
            case .right: return .right
            case nil: return .none
            }
        }
        return MDBlock(
            content: .table(TableData(rows: rows, alignments: alignments, delimiterRange: delimiterRange)),
            range: range, contentRange: range, depth: depth, quoteDepth: quoteDepth
        )
    }

    private mutating func cells(of container: Markup) -> [TableCell] {
        container.children.compactMap { child in
            guard let cell = child as? Markdown.Table.Cell,
                  let range = map.range(cell.range, lineOffset: lineOffset)
            else { return nil }
            let spans = inlines.spans(for: cell, bounds: range)
            let content = spans.isEmpty
                ? emptyCellContentRange(in: range)
                : NSRange(
                    location: spans[0].range.location,
                    length: max(0, spans[spans.count - 1].range.upperBound - spans[0].range.location)
                )
            return TableCell(range: range, contentRange: content, inlines: spans)
        }
    }

    /// Content bounds for a cell with no inline children.
    ///
    /// A cell's own range reaches across the row's `|`, and with no span to bound
    /// the content the whole range was taken as content.  So an *empty* cell's
    /// content was a pipe: a headerless table (`| | | |`, which is how a
    /// keybinding table is usually written) drew stray delimiter glyphs where its
    /// header row should have been blank, and every "is this header empty?"
    /// question answered no — which is why the renderer's own fallback for a
    /// missing label never fired.
    private func emptyCellContentRange(in range: NSRange) -> NSRange {
        var start = range.location
        var end = min(range.upperBound, text.length)
        while start < end, isCellPadding(text.character(at: start)) { start += 1 }
        while end > start, isCellPadding(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    private func isCellPadding(_ character: unichar) -> Bool {
        character == 0x7C || character == 0x20 || character == 0x09
    }

    // MARK: Synthetic blocks

    func frontMatterBlock(_ front: FrontMatter) -> MDBlock {
        MDBlock(
            content: .frontMatter(front),
            range: front.range,
            contentRange: front.bodyRange,
            markerRange: NSRange(
                location: front.range.location,
                length: max(0, front.bodyRange.location - front.range.location)
            ),
            trailingMarkerRange: NSRange(
                location: front.bodyRange.upperBound,
                length: max(0, front.range.upperBound - front.bodyRange.upperBound)
            ),
            depth: 1
        )
    }

    /// A footnote definition either survives as a paragraph or is swallowed
    /// whole by cmark's link-reference-definition handling, depending on
    /// whether its body happens to look like a URL.  Cover both: retype the
    /// block if one exists, synthesise it if not.
    mutating func attachFootnoteDefinitions(
        _ children: inout [MDBlock], definitions: [SourceScanner.FootnoteDefinition]
    ) {
        for definition in definitions {
            if let existing = children.first(where: { $0.range.contains(offset: definition.range.location) }) {
                existing.content = .footnoteDefinition(identifier: definition.identifier)
                existing.markerRange = definition.markerRange
                existing.contentRange = NSRange(
                    location: definition.markerRange.upperBound,
                    length: max(0, existing.range.upperBound - definition.markerRange.upperBound)
                )
                existing.inlines = InlineSpan.clipLeading(existing.inlines, to: definition.markerRange.upperBound)
                continue
            }
            let block = MDBlock(
                content: .footnoteDefinition(identifier: definition.identifier),
                range: definition.range,
                contentRange: NSRange(
                    location: definition.markerRange.upperBound,
                    length: max(0, definition.range.upperBound - definition.markerRange.upperBound)
                ),
                markerRange: definition.markerRange,
                depth: 1
            )
            let insertion = children.firstIndex { $0.range.location > definition.range.location }
            children.insert(block, at: insertion ?? children.count)
        }
    }
}

// MARK: - Identity and hashing

enum BlockIdentifier {
    /// `BlockIdentity` is (kind, ordinal-among-same-kind-siblings), which keeps
    /// fold state attached to "the third code block in this section" rather
    /// than to a byte offset that an agent rewrite invalidates.
    static func assign(_ root: MDBlock) {
        assign(children: root.children)
    }

    private static func assign(children: [MDBlock]) {
        var counters: [Int: Int] = [:]
        for child in children {
            let kind = discriminator(child.content)
            let ordinal = counters[kind, default: 0]
            counters[kind] = ordinal + 1
            child.identity = BlockIdentity(kind: kind, ordinal: ordinal)
            assign(children: child.children)
        }
    }

    static func discriminator(_ content: BlockContent) -> Int {
        switch content {
        case .document: return 0
        case .heading(let level): return 100 + level
        case .paragraph: return 2
        case .blockQuote: return 3
        case .callout: return 4
        case .list: return 5
        case .listItem: return 6
        case .codeBlock: return 7
        case .mermaid: return 8
        case .mathBlock: return 9
        case .table: return 10
        case .thematicBreak: return 11
        case .htmlBlock: return 12
        case .frontMatter: return 13
        case .footnoteDefinition: return 14
        }
    }
}

enum SubtreeHasher {
    /// Hashes kind, source bytes and children (§3.5).  Leaf blocks hash their
    /// own text; containers hash their marker plus their children's hashes, so
    /// an unchanged subtree keeps its hash even when it moves in the document.
    static func hash(_ block: MDBlock, in text: NSString) {
        for child in block.children { hash(child, in: text) }

        var h = FNV.combine(FNV.offsetBasis, UInt64(BlockIdentifier.discriminator(block.content)))
        if block.children.isEmpty {
            h = FNV.combine(h, text, range: clamp(block.range, to: text.length))
        } else {
            // A container's own source is not just its first line: blockquote,
            // list and callout markers on continuation lines sit *between* the
            // children, and blank quote lines (a lone `>`) carry no child at
            // all.  Hash every gap plus the trailing gap so an edit there is
            // visible to the diff instead of being skipped as "no child".
            let full = clamp(block.range, to: text.length)
            var scan = full.location
            for child in block.children {
                let childRange = clamp(child.range, to: text.length)
                if childRange.location > scan {
                    h = FNV.combine(h, text, range: NSRange(location: scan, length: childRange.location - scan))
                }
                h = FNV.combine(h, child.subtreeHash)
                if childRange.upperBound > scan { scan = childRange.upperBound }
            }
            if full.upperBound > scan {
                h = FNV.combine(h, text, range: NSRange(location: scan, length: full.upperBound - scan))
            }
        }
        block.subtreeHash = h
    }

    /// Hashes only a container's own bytes (kind + gaps between children),
    /// ignoring the children's hashes.  Used by the diff to detect a marker-only
    /// edit — e.g. a blank `>` quote line being added or removed — that leaves
    /// every child's subtree unchanged.
    static func frameworkHash(_ block: MDBlock, in text: NSString) -> UInt64 {
        var h = FNV.combine(FNV.offsetBasis, UInt64(BlockIdentifier.discriminator(block.content)))
        let full = clamp(block.range, to: text.length)
        var scan = full.location
        for child in block.children {
            let childRange = clamp(child.range, to: text.length)
            if childRange.location > scan {
                h = FNV.combine(h, text, range: NSRange(location: scan, length: childRange.location - scan))
            }
            if childRange.upperBound > scan { scan = childRange.upperBound }
        }
        if full.upperBound > scan {
            h = FNV.combine(h, text, range: NSRange(location: scan, length: full.upperBound - scan))
        }
        return h
    }

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = max(0, min(range.location, length))
        return NSRange(location: location, length: max(0, min(range.length, length - location)))
    }
}
