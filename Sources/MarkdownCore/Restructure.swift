import Foundation

public enum MoveDirection: Sendable { case up, down }

// MARK: - Restructuring (§9.2)
//
// Promote/demote/move/convert/sort, plus the table operations §6.3 drives from
// the pointer.  Everything returns `[TextEdit]` so §9.1's accept/reject sheet
// and plain-text undo work uniformly (§3.1: "Undo is plain text undo").
//
// §14 calls out the trap in `moveSection` explicitly: "Moving a heading means
// moving its subtree, fixing up sibling heading levels, and preserving the
// exact blank-line structure around it."  The approach here is to make section
// boundaries land on line starts and to let a section own the blank lines that
// follow it, so a move is a pure cut-and-paste of whole lines with no
// whitespace arithmetic at all.

public enum Restructure {

    // MARK: Headings

    public static func promoteHeading(_ doc: ParsedDocument, headingIndex: Int) -> [TextEdit] {
        relevel(doc, headingIndex: headingIndex, delta: -1)
    }

    public static func demoteHeading(_ doc: ParsedDocument, headingIndex: Int) -> [TextEdit] {
        relevel(doc, headingIndex: headingIndex, delta: +1)
    }

    /// Sets one heading subtree to an exact root level while preserving the
    /// relative depth of every descendant. This is the direct H1...H6 path;
    /// it shares the same subtree invariant as promote/demote.
    public static func setHeadingLevel(
        _ doc: ParsedDocument, headingIndex: Int, level: Int
    ) -> [TextEdit] {
        guard doc.headings.indices.contains(headingIndex), (1...6).contains(level) else { return [] }
        return relevel(doc, headingIndex: headingIndex, delta: level - doc.headings[headingIndex].level)
    }

    /// Converts an ATX or setext heading to ordinary body text without
    /// guessing marker widths. `contentRange` is parser-owned, so this also
    /// handles legal compact headings such as `#Title`, extra marker spacing,
    /// and closing hash runs without deleting title characters.
    public static func headingToBodyText(
        _ doc: ParsedDocument, headingIndex: Int
    ) -> [TextEdit] {
        guard doc.headings.indices.contains(headingIndex) else { return [] }
        let heading = doc.headings[headingIndex]
        let firstLine = doc.range(ofLine: doc.line(at: heading.range.location))

        if heading.range.upperBound > firstLine.upperBound {
            let underlineNumber = doc.line(at: heading.range.upperBound - 1)
            let underlineLine = doc.range(ofLine: underlineNumber)
            guard underlineLine.location > firstLine.location else { return [] }
            let removalEnd = underlineNumber < doc.lineStarts.count
                ? doc.lineStarts[underlineNumber]
                : doc.length
            return [TextEdit(
                range: NSRange(
                    location: underlineLine.location,
                    length: removalEnd - underlineLine.location
                ),
                replacement: "",
                summary: "Heading to body text"
            )]
        }

        // Anchor at the parser-owned block start. For a plain ATX line that
        // sits just past the leading indent; for a heading inside a
        // blockquote or list item it sits past the container marker, which
        // must survive the conversion instead of being stripped away.
        let markerLocation = heading.range.location
        guard markerLocation >= firstLine.location,
              markerLocation <= firstLine.upperBound,
              heading.contentRange.location >= markerLocation,
              heading.contentRange.location <= firstLine.upperBound
        else { return [] }
        var edits = [TextEdit(
            range: NSRange(
                location: markerLocation,
                length: heading.contentRange.location - markerLocation
            ),
            replacement: "",
            summary: "Heading to body text"
        )]
        if heading.contentRange.upperBound < firstLine.upperBound {
            edits.append(TextEdit(
                range: NSRange(
                    location: heading.contentRange.upperBound,
                    length: firstLine.upperBound - heading.contentRange.upperBound
                ),
                replacement: "",
                summary: "Remove closing heading marker"
            ))
        }
        return edits.filter { $0.range.length > 0 }
    }

    /// Moves the whole subtree: the heading and every heading beneath it shift
    /// by `delta`, clamped to 1...6.  A no-op at the clamp rather than a
    /// partial move, so the subtree's shape is never flattened.
    private static func relevel(_ doc: ParsedDocument, headingIndex: Int, delta: Int) -> [TextEdit] {
        guard doc.headings.indices.contains(headingIndex) else { return [] }
        guard delta != 0 else { return [] }
        let root = doc.headings[headingIndex]
        let target = root.level + delta
        guard target >= 1, target <= 6 else { return [] }

        let subtreeEnd = doc.headings[(headingIndex + 1)...]
            .firstIndex { $0.level <= root.level } ?? doc.headings.endIndex
        let subtree = doc.headings[headingIndex..<subtreeEnd]
        guard subtree.allSatisfy({ (1...6).contains($0.level + delta) }) else { return [] }

        var edits: [TextEdit] = []
        for heading in subtree {
            let level = heading.level + delta
            guard level != heading.level, let edit = rewriteLevel(doc, heading, to: level) else { continue }
            edits.append(edit)
        }
        return edits
    }

    private static func rewriteLevel(
        _ doc: ParsedDocument, _ heading: HeadingNode, to level: Int
    ) -> TextEdit? {
        let line = doc.range(ofLine: doc.line(at: heading.range.location))

        // A setext heading's block spans its underline line; an ATX heading
        // is always confined to its own source line. Only a genuine setext
        // shape may consume a second line. (A heading nested in a blockquote
        // or list item also fails the naive "line starts with N hashes"
        // probe below, because the container marker sits in front — it must
        // never fall into the two-line path.)
        let isSetext = heading.range.upperBound > line.upperBound

        if isSetext {
            // Setext can express only H1/H2. The direct picker still promises
            // H1...H6, so normalize this heading to ATX while preserving the
            // container prefix before the block start, the title's exact
            // source bytes, and the original line ending.  The *source*
            // span, not `heading.title`: the parsed title is plain text, and
            // rebuilding from it would strip the emphasis and code markers
            // the line carries.
            let titleLineNumber = doc.line(at: line.location)
            guard titleLineNumber < doc.lineStarts.count else { return nil }
            // A setext underline always sits on the immediately following
            // source line. (The block range itself cannot be trusted for
            // this: inside a list item cmark reports an end past the
            // container's next sibling.) `lineStarts` is indexed by 0-based
            // line, so the 1-based number of a line indexes the *following*
            // line's start.
            let underlineStart = doc.lineStarts[titleLineNumber]
            let removalEnd = titleLineNumber + 1 < doc.lineStarts.count
                ? doc.lineStarts[titleLineNumber + 1]
                : doc.length
            // Defensive shape check: only consume the second line when it
            // really is an underline (`=` / `-` runs). Anything else must
            // never be deleted by a level change.
            let underlineText = doc.substring(
                NSRange(location: underlineStart, length: removalEnd - underlineStart)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !underlineText.isEmpty, underlineText.allSatisfy({ $0 == "=" || $0 == "-" })
            else { return nil }
            let prefixLength = max(0, min(heading.range.location - line.location, line.length))
            let prefix = doc.substring(NSRange(location: line.location, length: prefixLength))
            let separator = line.upperBound < underlineStart
                ? doc.substring(NSRange(
                    location: line.upperBound,
                    length: underlineStart - line.upperBound
                ))
                : ""
            let rawTitle = doc.substring(heading.contentRange)
            return TextEdit(
                range: NSRange(location: line.location, length: removalEnd - line.location),
                replacement: "\(prefix)\(String(repeating: "#", count: level)) \(rawTitle)\(separator)",
                summary: "H\(heading.level) → H\(level): \(heading.title)"
            )
        }

        // ATX: replace exactly the `#` run at the parser-owned block start.
        // For a plain line that equals the old leading-indent position; for a
        // nested heading the run sits behind the container marker.
        let nsSource = doc.substring(line) as NSString
        let columnInLine = heading.range.location - line.location
        guard columnInLine >= 0, columnInLine <= nsSource.length else { return nil }
        let hashes = nsSource.substring(from: columnInLine).prefix { $0 == "#" }
        guard hashes.utf16.count == heading.level else { return nil }
        return TextEdit(
            range: NSRange(location: heading.range.location, length: hashes.utf16.count),
            replacement: String(repeating: "#", count: level),
            summary: "H\(heading.level) → H\(level): \(heading.title)"
        )
    }

    // MARK: Moving

    /// Moves `headingIndex`'s section so it starts where `targetIndex`'s does.
    /// `targetIndex == doc.headings.count` moves it to the end of the document.
    ///
    /// The blank lines between two sections are a property of the *join*, not
    /// of either section, which is the insight §14's warning turns on.  So the
    /// section is split into its content and its trailing blank run, the
    /// content moves, and each end of the move re-establishes the separator
    /// its position calls for.  A section moved to and from the end of a file
    /// with no final newline therefore round-trips exactly.
    public static func moveSection(
        _ doc: ParsedDocument, headingIndex: Int, before targetIndex: Int
    ) -> [TextEdit] {
        guard doc.headings.indices.contains(headingIndex) else { return [] }
        let section = doc.headings[headingIndex].sectionRange
        let destination = targetIndex < doc.headings.count
            ? doc.headings[max(0, targetIndex)].sectionRange.location
            : doc.length
        guard destination <= section.location || destination >= section.upperBound else { return [] }
        guard destination != section.location else { return [] }

        let text = doc.text as NSString
        let ending = DocumentIO.dominantLineEnding(doc.text).rawValue
        let title = doc.headings[headingIndex].title
        let split = SectionSplit(section, in: text)
        let leadingSeparator = Self.blankSeparator(before: section.location, in: text)

        // Cut.  A section that owns a trailing blank run takes it along and the
        // separator before it survives to join its neighbours.  The last
        // section owns nothing, so the run before it — and the final newline,
        // if the file has none of its own — go too.  The separator is measured
        // in its own bytes: a mixed-ending file keeps whatever terminators it
        // actually had instead of being rebuilt as LF.
        var cut = section
        if split.trailingBlanks > 0 || section.upperBound < doc.length {
            cut = section
        } else {
            let unterminatedWidth = split.isTerminated
                ? 0
                : (Self.terminator(endingAt: section.location, in: text)?.utf16.count ?? ending.utf16.count)
            let extra = leadingSeparator.utf16.count + unterminatedWidth
            cut = NSRange(
                location: max(0, section.location - extra),
                length: section.length + min(extra, section.location)
            )
        }

        // Paste.
        let insertion: String
        if destination >= doc.length {
            // Appending: the separator has to go in front, since there is no
            // following section to carry one.
            let separator = split.trailingBlanks > 0
                ? split.trailingSeparator
                : (leadingSeparator.isEmpty ? ending : leadingSeparator)
            insertion = separator + split.core
        } else {
            var separator = Self.blankSeparator(before: destination, in: text)
            if separator.isEmpty { separator = leadingSeparator }
            insertion = split.terminatedCore(ending) + separator
        }

        return [
            TextEdit(range: cut, replacement: "", summary: "Move section: \(title)"),
            TextEdit(
                range: NSRange(location: destination, length: 0),
                replacement: insertion,
                summary: "Move section: \(title)"
            ),
        ]
    }

    /// The line terminator that ends exactly at `offset` (`\r\n`, `\n`, or a
    /// lone `\r`), or `nil` when no terminator ends there.
    private static func terminator(endingAt offset: Int, in text: NSString) -> String? {
        guard offset > 0 else { return nil }
        if offset >= 2,
           text.character(at: offset - 2) == 0x0D, text.character(at: offset - 1) == 0x0A {
            return "\r\n"
        }
        if text.character(at: offset - 1) == 0x0A { return "\n" }
        if text.character(at: offset - 1) == 0x0D { return "\r" }
        return nil
    }

    /// A section's content, its terminator and the blank run that trails it.
    /// Terminators are recognised by width (`\r\n`, `\n`, `\r`), so a move
    /// through a CRLF, classic-Mac, or mixed file keeps the bytes it found.
    private struct SectionSplit {
        var core: String
        var isTerminated: Bool
        var trailingBlanks: Int
        /// The exact terminator bytes of the trailing blank run, in document
        /// order — what a move must hand back when it re-establishes the gap.
        var trailingSeparator: String

        init(_ section: NSRange, in text: NSString) {
            var end = section.upperBound
            var stripped: [String] = []
            while let terminator = Restructure.terminator(endingAt: end, in: text),
                  end - terminator.utf16.count >= section.location {
                end -= terminator.utf16.count
                stripped.append(terminator)
            }
            isTerminated = !stripped.isEmpty
            // `stripped` is in reverse document order; the first element is
            // the terminator that directly follows the content.
            if let own = stripped.last {
                core = text.substring(with: NSRange(
                    location: section.location, length: end + own.utf16.count - section.location
                ))
            } else {
                core = text.substring(with: NSRange(location: section.location, length: end - section.location))
            }
            trailingBlanks = max(0, stripped.count - (isTerminated ? 1 : 0))
            trailingSeparator = stripped.dropLast(isTerminated ? 1 : 0).reversed().joined()
        }

        /// The content with a line terminator, for pasting somewhere that is
        /// not the end of the document.
        func terminatedCore(_ ending: String) -> String {
            if isTerminated { return core }
            return core.hasSuffix("\n") || core.hasSuffix("\r") ? core : core + ending
        }
    }

    /// The blank-line separator immediately before `offset`, which is a line
    /// start: the run of terminators there, less the previous line's own
    /// terminator, as the exact bytes found in the document.
    private static func blankSeparator(before offset: Int, in text: NSString) -> String {
        var terminators: [String] = []
        var index = offset
        while let terminator = Self.terminator(endingAt: index, in: text) {
            terminators.append(terminator)
            index -= terminator.utf16.count
        }
        // `terminators[0]` is the previous line's own terminator; the rest are
        // the blank lines that make up the separator.
        return terminators.dropFirst().reversed().joined()
    }

    /// Moves the block containing `offset` past its neighbouring sibling.  The
    /// gap between the two — blank lines and all — stays exactly where it is,
    /// which is what keeps `⌥⌘↑`/`⌥⌘↓` from slowly eating a document's spacing.
    public static func moveBlock(
        _ doc: ParsedDocument, containing offset: Int, _ direction: MoveDirection
    ) -> [TextEdit] {
        guard let (parent, index) = movableBlock(doc, containing: offset) else { return [] }
        let siblings = parent.children
        let otherIndex = direction == .up ? index - 1 : index + 1
        guard siblings.indices.contains(otherIndex) else { return [] }

        let first = siblings[min(index, otherIndex)]
        let second = siblings[max(index, otherIndex)]
        let text = doc.text as NSString
        let span = NSRange(
            location: first.range.location,
            length: second.range.upperBound - first.range.location
        )
        let gap = NSRange(
            location: first.range.upperBound,
            length: max(0, second.range.location - first.range.upperBound)
        )
        let replacement = text.substring(with: second.range)
            + text.substring(with: gap)
            + text.substring(with: first.range)
        guard replacement != text.substring(with: span) else { return [] }
        return [TextEdit(
            range: span, replacement: replacement,
            summary: direction == .up ? "Move block up" : "Move block down"
        )]
    }

    /// The block a move should act on: the innermost list item if there is one,
    /// otherwise the top-level block.  Moving the paragraph *inside* a list
    /// item is never what the user means.
    private static func movableBlock(
        _ doc: ParsedDocument, containing offset: Int
    ) -> (parent: MDBlock, index: Int)? {
        var chain: [(MDBlock, MDBlock)] = []  // (parent, child)
        func descend(_ block: MDBlock) {
            for child in block.children where child.range.touches(offset: offset) {
                chain.append((block, child))
                descend(child)
                return
            }
        }
        descend(doc.root)
        guard !chain.isEmpty else { return nil }

        let chosen = chain.last { parent, _ in
            if case .list = parent.content { return true }
            if case .document = parent.content { return true }
            return false
        } ?? chain[0]
        guard let index = chosen.0.children.firstIndex(where: { $0 === chosen.1 }) else { return nil }
        return (chosen.0, index)
    }

    // MARK: Conversion

    /// Converts the lines touched by `range` between paragraph, bullet list,
    /// numbered list, task list and blockquote.  Operates line by line so a
    /// partial selection converts exactly the lines the user highlighted.
    public static func convert(
        _ doc: ParsedDocument, range: NSRange, to conversion: ListConversion
    ) -> [TextEdit] {
        let firstLine = doc.line(at: max(0, range.location)) - 1
        let lastLine = doc.line(at: max(range.location, range.upperBound - 1)) - 1
        guard firstLine <= lastLine else { return [] }

        var edits: [TextEdit] = []
        var ordinal = 1
        for line in firstLine...lastLine {
            let lineRange = doc.range(ofLine: line + 1)
            let source = doc.substring(lineRange)
            if source.isBlankLine, conversion != .blockquote { continue }

            let indent = source.leadingIndent
            let stripped = BlockMarker.strip(String(source.dropFirst(indent.count)))
            let replacement: String
            switch conversion {
            case .paragraph: replacement = indent + stripped
            case .bulletList: replacement = indent + "- " + stripped
            case .numberedList:
                replacement = indent + "\(ordinal). " + stripped
                ordinal += 1
            case .taskList: replacement = indent + "- [ ] " + stripped
            case .blockquote: replacement = indent + (stripped.isEmpty ? ">" : "> " + stripped)
            }
            guard replacement != source else { continue }
            edits.append(TextEdit(
                range: lineRange, replacement: replacement,
                summary: "Convert to \(conversion.title)"
            ))
        }
        return edits
    }

    // MARK: Sorting

    public static func sortList(
        _ doc: ParsedDocument, containing offset: Int, order: ListSortOrder
    ) -> [TextEdit] {
        guard let list = enclosingList(doc.root, offset: offset) else { return [] }
        guard case .list(let ordered, let start, _, _) = list.content else { return [] }
        let items = list.children.filter { if case .listItem = $0.content { return true } else { return false } }
        guard items.count > 1 else { return [] }

        let text = doc.text as NSString
        let bodies = items.map { text.substring(with: $0.range) }
        let separators = zip(items, items.dropFirst()).map { previous, next in
            text.substring(with: NSRange(
                location: previous.range.upperBound,
                length: max(0, next.range.location - previous.range.upperBound)
            ))
        }

        let keys = items.map { item -> (text: String, checked: Bool?) in
            var checked: Bool?
            if case .listItem(_, let box) = item.content { checked = box?.isChecked }
            return (PlainText.of(item, in: text).lowercased(), checked)
        }

        var order_ = Array(items.indices)
        switch order {
        case .alphabetical:
            order_.sort { keys[$0].text < keys[$1].text }
        case .reverseAlphabetical:
            order_.sort { keys[$0].text > keys[$1].text }
        case .uncheckedFirst:
            order_ = stableSort(order_) { rank(keys[$0].checked, uncheckedFirst: true) < rank(keys[$1].checked, uncheckedFirst: true) }
        case .checkedFirst:
            order_ = stableSort(order_) { rank(keys[$0].checked, uncheckedFirst: false) < rank(keys[$1].checked, uncheckedFirst: false) }
        }
        guard order_ != Array(items.indices) else { return [] }

        var result = ""
        for (position, source) in order_.enumerated() {
            var body = bodies[source]
            // A sorted ordered list with its original numbers scrambled would
            // be worse than not sorting at all, so renumber as we go.
            if ordered { body = renumbered(body, to: start + position) }
            result += body
            if position < separators.count { result += separators[position] }
        }
        let span = NSRange(
            location: items[0].range.location,
            length: items[items.count - 1].range.upperBound - items[0].range.location
        )
        guard result != text.substring(with: span) else { return [] }
        return [TextEdit(range: span, replacement: result, summary: "Sort list (\(order.rawValue))")]
    }

    private static func rank(_ checked: Bool?, uncheckedFirst: Bool) -> Int {
        guard let checked else { return 2 }
        if uncheckedFirst { return checked ? 1 : 0 }
        return checked ? 0 : 1
    }

    private static func stableSort(_ indices: [Int], by less: (Int, Int) -> Bool) -> [Int] {
        indices.enumerated()
            .sorted { a, b in less(a.element, b.element) || (!less(b.element, a.element) && a.offset < b.offset) }
            .map(\.element)
    }

    private static func renumbered(_ item: String, to number: Int) -> String {
        let indent = item.leadingIndent
        let rest = item.dropFirst(indent.count)
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty else { return item }
        return indent + String(number) + rest.dropFirst(digits.count)
    }

    private static func enclosingList(_ block: MDBlock, offset: Int) -> MDBlock? {
        var found: MDBlock?
        block.walkPruning { candidate in
            guard candidate.range.touches(offset: offset) else { return false }
            if case .list = candidate.content { found = candidate }
            return true
        }
        return found
    }

    // MARK: Table of contents

    /// Markdown bullet list of anchor links, indented by heading depth.
    public static func tableOfContents(_ doc: ParsedDocument, maxLevel: Int) -> String {
        let headings = doc.headings.filter { $0.level <= maxLevel && !$0.title.isEmpty }
        guard let minimum = headings.map(\.level).min() else { return "" }
        let ending = DocumentIO.dominantLineEnding(doc.text).rawValue
        return headings.map { heading in
            let indent = String(repeating: "  ", count: heading.level - minimum)
            return "\(indent)- [\(escaped(heading.title))](#\(heading.slug))"
        }.joined(separator: ending)
    }

    private static func escaped(_ title: String) -> String {
        title
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    // MARK: Tasks

    /// A one-character replacement, which keeps the edit trivial to undo and
    /// lets §7.1's "click any checkbox, the file is written immediately" stay
    /// cheap even on a large document.
    public static func toggleTask(_ doc: ParsedDocument, atMarkOffset offset: Int) -> TextEdit? {
        guard let task = doc.tasks.first(where: { $0.markRange.touches(offset: offset) })
            ?? doc.tasks.first(where: { taskLine(doc, $0) == doc.line(at: offset) })
        else { return nil }
        return TextEdit(
            range: task.markRange,
            replacement: task.isChecked ? " " : "x",
            summary: task.isChecked ? "Uncheck task" : "Check task"
        )
    }

    private static func taskLine(_ doc: ParsedDocument, _ task: TaskItem) -> Int {
        doc.line(at: task.markRange.location)
    }

    // MARK: Tables (§6.3)

    public static func realignTable(_ doc: ParsedDocument, tableRange: NSRange) -> [TextEdit] {
        guard let (block, table) = table(doc, at: tableRange) else { return [] }
        let text = doc.text as NSString
        let range = TableFormatter.sourceRange(of: table, fallback: block.range)
        let rendered = TableFormatter.render(TableFormatter.model(of: table, in: text))
        guard !rendered.isEmpty, rendered != text.substring(with: range) else { return [] }
        return [TextEdit(range: range, replacement: rendered, summary: "Realign table")]
    }

    public static func setColumnAlignment(
        _ doc: ParsedDocument, tableRange: NSRange, column: Int, alignment: TableAlignment
    ) -> [TextEdit] {
        guard let (block, table) = table(doc, at: tableRange) else { return [] }
        let text = doc.text as NSString
        var model = TableFormatter.model(of: table, in: text)
        let columns = model.columnCount
        guard column >= 0, column < columns else { return [] }
        while model.alignments.count < columns { model.alignments.append(.none) }
        guard model.alignments[column] != alignment else { return [] }
        model.alignments[column] = alignment

        let range = TableFormatter.sourceRange(of: table, fallback: block.range)
        return [TextEdit(
            range: range, replacement: TableFormatter.render(model),
            summary: "Align column \(column + 1) \(alignment.rawValue)"
        )]
    }

    /// Inserts an empty row after `afterRow`, an index into `TableData.rows`
    /// where 0 is the header.  A negative index inserts as the first body row.
    public static func insertRow(
        _ doc: ParsedDocument, tableRange: NSRange, afterRow: Int
    ) -> [TextEdit] {
        guard let (block, table) = table(doc, at: tableRange) else { return [] }
        let text = doc.text as NSString
        var model = TableFormatter.model(of: table, in: text)
        let position = min(model.rows.count, max(1, afterRow + 1))
        model.rows.insert([String](repeating: "", count: model.columnCount), at: position)

        let range = TableFormatter.sourceRange(of: table, fallback: block.range)
        return [TextEdit(
            range: range, replacement: TableFormatter.render(model),
            summary: "Insert table row"
        )]
    }

    /// Deletes `row` (an index into `TableData.rows`).  Refuses to delete the
    /// header, because a GFM table without one is not a table.
    public static func deleteRow(
        _ doc: ParsedDocument, tableRange: NSRange, row: Int
    ) -> [TextEdit] {
        guard let (block, table) = table(doc, at: tableRange) else { return [] }
        let text = doc.text as NSString
        var model = TableFormatter.model(of: table, in: text)
        guard row > 0, row < model.rows.count else { return [] }
        model.rows.remove(at: row)

        let range = TableFormatter.sourceRange(of: table, fallback: block.range)
        return [TextEdit(
            range: range, replacement: TableFormatter.render(model),
            summary: "Delete table row"
        )]
    }

    private static func table(
        _ doc: ParsedDocument, at range: NSRange
    ) -> (block: MDBlock, table: TableData)? {
        var result: (MDBlock, TableData)?
        doc.root.walk { block in
            guard result == nil, case .table(let data) = block.content else { return }
            let full = TableFormatter.sourceRange(of: data, fallback: block.range)
            if full.location < max(range.upperBound, range.location + 1), range.location < full.upperBound {
                result = (block, data)
            }
        }
        return result
    }

    // MARK: Tasks

    /// Adds `- [ ] text` after the last task of the section `headingIndex`
    /// names — after that task's whole *block*, so an anchor with nested
    /// children is never split from its family.  With no matching task (a
    /// section without tasks, or a document without any) the new task starts
    /// its own list at the end of the document, behind exactly one blank line
    /// of separation — none when the file is empty or already ends blank.
    ///
    /// Either way the edit is a single zero-length insertion on a line
    /// boundary; everything already in the file stays byte-identical.
    public static func insertTask(
        _ doc: ParsedDocument, text: String, headingIndex: Int?
    ) -> [TextEdit] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let anchor = doc.tasks.last(where: { $0.headingIndex == headingIndex }) {
            let block = taskBlock(doc, at: doc.line(at: anchor.markRange.location))
            // A block that ran to EOF without a trailing newline has no line
            // start after it, so the separator goes in front of the new task
            // instead of behind it.
            let needsLeadingNewline = block.upperBound >= doc.length && !doc.text.hasSuffix("\n")
            return [TextEdit(
                range: NSRange(location: block.upperBound, length: 0),
                replacement: needsLeadingNewline ? "\n- [ ] \(trimmed)\n" : "- [ ] \(trimmed)\n",
                summary: "Add task"
            )]
        }

        // No anchor: append at the end of the document, leaving exactly one
        // blank line between the new list and whatever precedes it.
        let replacement: String
        if doc.length == 0 || doc.text.hasSuffix("\n\n") {
            replacement = "- [ ] \(trimmed)\n"
        } else if doc.text.hasSuffix("\n") {
            replacement = "\n- [ ] \(trimmed)\n"
        } else {
            replacement = "\n\n- [ ] \(trimmed)\n"
        }
        return [TextEdit(
            range: NSRange(location: doc.length, length: 0),
            replacement: replacement,
            summary: "Add task"
        )]
    }

    /// Moves `taskIndex` among its siblings — same section, same indent level,
    /// same parent — so it lands immediately before `targetIndex`, or after
    /// the last sibling when `targetIndex` is nil.  Crossing a section or a
    /// nesting level would be a re-parenting, not a reorder, and is refused.
    /// Blank lines between two lists don't split siblinghood: the test runs
    /// over the task array, not the source lines.
    ///
    /// The task travels with its block, so children ride along.  The result
    /// is two edits in original coordinates — cut the block, paste its text
    /// at the destination — which apply cleanly back to front because the
    /// destination is a line start (or EOF) that never falls inside the cut.
    ///
    /// Newline discipline keeps the file's final-newline state intact: a
    /// block that ends the file without a trailing `\n` borrows the newline
    /// before it (the cut reaches one character back, the paste gains one),
    /// and a paste aimed at an unterminated EOF brings its own leading `\n`.
    public static func moveTask(
        _ doc: ParsedDocument, taskIndex: Int, before targetIndex: Int?
    ) -> [TextEdit] {
        let tasks = doc.tasks
        guard tasks.indices.contains(taskIndex) else { return [] }
        if let targetIndex, targetIndex == taskIndex { return [] }

        let source = tasks[taskIndex]
        let sourceParent = taskParent(of: taskIndex, in: tasks)
        func isSibling(_ index: Int) -> Bool {
            tasks[index].headingIndex == source.headingIndex
                && tasks[index].indentLevel == source.indentLevel
                && taskParent(of: index, in: tasks) == sourceParent
        }

        let insertion: Int
        if let targetIndex {
            guard tasks.indices.contains(targetIndex), isSibling(targetIndex) else { return [] }
            insertion = doc.lineStarts[doc.line(at: tasks[targetIndex].markRange.location) - 1]
        } else {
            // After the last sibling's block — unless the source already is
            // that sibling, which is where the move would put it.
            guard let last = tasks.indices.filter(isSibling).last, last != taskIndex else { return [] }
            insertion = taskBlock(doc, at: doc.line(at: tasks[last].markRange.location)).upperBound
        }

        let block = taskBlock(doc, at: doc.line(at: source.markRange.location))
        guard insertion != block.location else { return [] }  // already in position

        var cut = block
        var paste = doc.substring(block)
        if paste.hasSuffix("\n") {
            // Landing at an EOF with no trailing newline (only possible when
            // moving to the end): the separator goes in front and the block
            // leaves its own terminator where it was.
            if insertion >= doc.length, !doc.text.hasSuffix("\n") {
                paste = "\n" + String(paste.dropLast())
            }
        } else {
            // The block ends the file without a newline: cut the separator
            // before it too (when there is one) so no orphaned blank line is
            // left behind, and restore the terminator on the pasted copy —
            // its destination here is always a line start.
            if block.location > 0 {
                cut = NSRange(location: block.location - 1, length: block.length + 1)
            }
            paste += "\n"
        }

        return [
            TextEdit(range: cut, replacement: "", summary: "Move task"),
            TextEdit(
                range: NSRange(location: insertion, length: 0),
                replacement: paste,
                summary: "Move task"
            ),
        ]
    }

    /// The block a task owns for insertion and moving: its own line plus every
    /// following line that is non-blank and indented deeper than it — the
    /// children that ride along.  A blank line or a shallower line ends the
    /// block.  The range ends on a line start (or at EOF), so it spans whole
    /// lines, trailing newline included, and cuts and pastes without any
    /// whitespace arithmetic.
    private static func taskBlock(_ doc: ParsedDocument, at line: Int) -> NSRange {
        let start = doc.lineStarts[line - 1]
        let indent = doc.substring(doc.range(ofLine: line)).leadingIndent.count
        var next = line + 1
        while next <= doc.lineStarts.count {
            let source = doc.substring(doc.range(ofLine: next))
            guard !source.isBlankLine, source.leadingIndent.count > indent else { break }
            next += 1
        }
        let end = next <= doc.lineStarts.count ? doc.lineStarts[next - 1] : doc.length
        return NSRange(location: start, length: end - start)
    }

    /// A task's parent for sibling tests: the nearest preceding task in
    /// document order that sits shallower in the same section.
    private static func taskParent(of index: Int, in tasks: [TaskItem]) -> Int? {
        let task = tasks[index]
        var candidate = index - 1
        while candidate >= 0 {
            let preceding = tasks[candidate]
            if preceding.headingIndex == task.headingIndex,
               preceding.indentLevel < task.indentLevel {
                return candidate
            }
            candidate -= 1
        }
        return nil
    }
}

// MARK: - Block markers

enum BlockMarker {
    /// Removes a leading block marker — `#`, `>`, `-`, `1.`, `- [ ]` — leaving
    /// the line's content.  Used by conversion and by list continuation.
    static func strip(_ line: String) -> String {
        var rest = Substring(line)
        var changed = true
        while changed {
            changed = false
            if rest.hasPrefix(">") {
                rest = rest.dropFirst()
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                changed = true
                continue
            }
            let hashes = rest.prefix { $0 == "#" }
            if !hashes.isEmpty, hashes.count <= 6, rest.dropFirst(hashes.count).hasPrefix(" ") {
                rest = rest.dropFirst(hashes.count + 1)
                changed = true
                continue
            }
            if let bullet = rest.first, bullet == "-" || bullet == "*" || bullet == "+",
               rest.dropFirst().hasPrefix(" ") {
                rest = rest.dropFirst(2)
                changed = true
            } else {
                let digits = rest.prefix { $0.isNumber }
                if !digits.isEmpty {
                    let after = rest.dropFirst(digits.count)
                    if let punctuation = after.first, punctuation == "." || punctuation == ")",
                       after.dropFirst().hasPrefix(" ") {
                        rest = after.dropFirst(2)
                        changed = true
                    }
                }
            }
            if changed { continue }
            // A task marker only ever follows a bullet, which the branch above
            // has already consumed by the time we get here.
            break
        }
        if rest.hasPrefix("[ ] ") || rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") {
            rest = rest.dropFirst(4)
        }
        return String(rest)
    }
}
