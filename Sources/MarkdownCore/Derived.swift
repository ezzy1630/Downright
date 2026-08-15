import Foundation

// MARK: - Line-level source scan
//
// Two constructs never reach the AST: cmark consumes link reference
// definitions outright, and — with no footnote extension registered — a
// footnote definition is either eaten as a link reference definition or left
// as an ordinary paragraph, depending on whether its body happens to parse as
// a URL.  Both have to be recovered from the source, so both are found here in
// one pass, with fence tracking so a definition inside a code block is ignored.

struct SourceScanner {
    struct FootnoteDefinition {
        var identifier: String
        /// `[^id]: ` including the trailing space.
        var markerRange: NSRange
        /// The definition line plus any indented continuation lines.
        var range: NSRange
    }

    private(set) var footnoteDefinitions: [FootnoteDefinition] = []
    private(set) var linkReferences: [String: LinkReference] = [:]

    init(map: SourceMap) {
        let text = map.text
        var line = 0
        /// The open fence's character and run length.  CommonMark: a closing
        /// fence line is only fence characters and whitespace, and at least as
        /// long as the opening run — an info string (`\`\`\`ruby`) inside a
        /// longer fence is content, not a closer.
        var fence: (character: unichar, length: Int)?
        while line < map.lineCount {
            defer { line += 1 }
            let lineRange = map.contentRange(ofLine: line)
            let start = lineRange.location
            let end = lineRange.upperBound

            // Measure the leading indent and land on the first non-whitespace
            // offset in one pass over the UTF-16 buffer.  No line String is
            // materialised unless a `[` definition candidate actually shows up.
            var trimmedStart = start
            var indentColumns = 0
            while trimmedStart < end {
                let c = text.character(at: trimmedStart)
                if c == 0x20 {
                    trimmedStart += 1
                    indentColumns += 1
                } else if c == 0x09 {
                    trimmedStart += 1
                    indentColumns += 4 - (indentColumns % 4)
                } else {
                    break
                }
            }
            let trimmedLength = end - trimmedStart

            if let open = fence {
                if isClosingFenceLine(text, at: trimmedStart, length: trimmedLength, fence: open) {
                    fence = nil
                }
                continue
            }
            if let backticks = fenceRun(text, at: trimmedStart, length: trimmedLength, character: 0x60),
               backticks >= 3 {
                fence = (0x60, backticks)
                continue
            }
            if let tildes = fenceRun(text, at: trimmedStart, length: trimmedLength, character: 0x7E),
               tildes >= 3 {
                fence = (0x7E, tildes)
                continue
            }
            guard indentColumns < 4, trimmedLength > 0,
                  text.character(at: trimmedStart) == 0x5B
            else { continue }

            guard let close = closingBracket(text, from: trimmedStart, to: end),
                  close + 1 < end,
                  text.character(at: close + 1) == 0x3A
            else { continue }

            let labelStart = trimmedStart + 1
            guard close > labelStart else { continue }
            let label = text.substring(with: NSRange(location: labelStart, length: close - labelStart))
            guard !label.isEmpty else { continue }
            let markerLength = (close - trimmedStart) + 2
            let indent = trimmedStart - start
            let bodyStart = lineRange.location + indent + markerLength
            let body = text.substring(with: NSRange(
                location: min(bodyStart, end), length: max(0, end - min(bodyStart, end))
            ))

            if label.hasPrefix("^") {
                let identifier = String(label.dropFirst())
                guard !identifier.isEmpty else { continue }
                var last = line
                while last + 1 < map.lineCount, isIndentedContinuation(map, line: last + 1) {
                    last += 1
                }
                let end_ = map.contentRange(ofLine: last).upperBound
                let leadingSpace = body.hasPrefix(" ") ? 1 : 0
                footnoteDefinitions.append(FootnoteDefinition(
                    identifier: identifier,
                    markerRange: NSRange(
                        location: lineRange.location,
                        length: bodyStart + leadingSpace - lineRange.location
                    ),
                    range: NSRange(location: lineRange.location, length: max(0, end_ - lineRange.location))
                ))
                line = last
                continue
            }

            let (destination, title) = destinationAndTitle(body)
            guard !destination.isEmpty else { continue }
            linkReferences[label.lowercased()] = LinkReference(
                identifier: label, destination: destination, title: title, range: lineRange
            )
        }
    }

    /// The leading run of `character` on a trimmed line, or `nil` when there is
    /// none.  ASCII units compare directly on the UTF-16 buffer.
    private func fenceRun(_ text: NSString, at offset: Int, length: Int, character: unichar) -> Int? {
        var run = 0
        while run < length, text.character(at: offset + run) == character { run += 1 }
        return run > 0 ? run : nil
    }

    /// CommonMark's closing-fence test: the same character as the opening
    /// fence, a run at least as long as (and no shorter than three), and
    /// nothing after it but spaces or tabs.  An info string does not close.
    private func isClosingFenceLine(
        _ text: NSString, at offset: Int, length: Int, fence: (character: unichar, length: Int)
    ) -> Bool {
        guard let run = fenceRun(text, at: offset, length: length, character: fence.character),
              run >= 3, run >= fence.length else { return false }
        var index = offset + run
        let end = offset + length
        while index < end {
            let c = text.character(at: index)
            if c != 0x20, c != 0x09 { return false }
            index += 1
        }
        return true
    }

    private func closingBracket(_ text: NSString, from start: Int, to end: Int) -> Int? {
        var depth = 0
        var index = start
        while index < end {
            switch text.character(at: index) {
            case 0x5B: depth += 1
            case 0x5D:
                depth -= 1
                if depth == 0 { return index }
            case 0x5C: index += 1
            default: break
            }
            index += 1
        }
        return nil
    }

    /// A footnote definition's continuation line: non-blank and indented at
    /// least four columns (a leading tab counts as four, per CommonMark).
    private func isIndentedContinuation(_ map: SourceMap, line: Int) -> Bool {
        let range = map.contentRange(ofLine: line)
        let text = map.text
        var columns = 0
        var sawContent = false
        var index = range.location
        let end = range.upperBound
        while index < end {
            let c = text.character(at: index)
            if c == 0x20 {
                columns += 1
            } else if c == 0x09 {
                columns += 4 - (columns % 4)
            } else {
                sawContent = true
                break
            }
            index += 1
        }
        guard sawContent else { return false }
        return columns >= 4
    }

    private func destinationAndTitle(_ body: String) -> (String, String?) {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return (trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "<>")), nil)
        }
        let destination = String(trimmed[trimmed.startIndex..<space])
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        var title = String(trimmed[space...]).trimmingCharacters(in: .whitespaces)
        if title.count >= 2, let first = title.first, let last = title.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") || (first == "(" && last == ")") {
            title = String(title.dropFirst().dropLast())
        }
        return (destination, title.isEmpty ? nil : title)
    }
}

// MARK: - Derived structures
//
// Outline, task list and footnote index, all computed in one walk so that
// nothing downstream has to re-traverse the tree to answer "which heading am I
// under" (§5.1 breadcrumb, §8.5 task grouping, §9.6 per-section read time).

struct DerivedStructures {
    var headings: [HeadingNode] = []
    var tasks: [TaskItem] = []
    var footnotes: [String: MDBlock] = [:]

    init(root: MDBlock, map: SourceMap) {
        var headingBlocks: [MDBlock] = []
        var taskItems: [(MDBlock, Int)] = []

        func walk(_ block: MDBlock, listDepth: Int) {
            switch block.content {
            case .heading:
                headingBlocks.append(block)
            case .listItem(_, let checkbox) where checkbox != nil:
                taskItems.append((block, max(0, listDepth - 1)))
            case .footnoteDefinition(let identifier):
                footnotes[identifier] = block
            default:
                break
            }
            let nextDepth: Int
            if case .list = block.content { nextDepth = listDepth + 1 } else { nextDepth = listDepth }
            for child in block.children { walk(child, listDepth: nextDepth) }
        }
        for child in root.children { walk(child, listDepth: 0) }

        headings = DerivedStructures.outline(headingBlocks, root: root, map: map)
        tasks = taskItems.map { block, indent in
            let checkbox: Checkbox
            if case .listItem(_, let box) = block.content, let box { checkbox = box } else {
                checkbox = Checkbox(isChecked: false, markRange: block.range)
            }
            return TaskItem(
                isChecked: checkbox.isChecked,
                markRange: checkbox.markRange,
                contentRange: block.contentRange,
                text: Self.taskLabel(for: block, in: map.text),
                headingIndex: headings.lastIndex { $0.range.location < block.range.location },
                indentLevel: indent
            )
        }
    }

    /// A task's label is its *own* source line, from just after the `[ ]`
    /// marker to that line's terminator.  `PlainText.of` recurses into child
    /// blocks when a list item carries no inline spans of its own, and a
    /// list item's `contentRange` spans its whole subtree — both would make a
    /// parent task read "Notarise and publish  Sparkle appcast  Ad-hoc signing
    /// for local runs".  The line-scoped slice ends the label at its own line
    /// terminator, so six source tasks stay six distinct labels.
    private static func taskLabel(for block: MDBlock, in text: NSString) -> String {
        let line = text.lineRange(for: NSRange(location: block.range.location, length: 0))
        let start = min(max(line.location, block.contentRange.location), line.upperBound)
        guard line.upperBound > start else { return "" }
        let label = text.substring(with: NSRange(location: start, length: line.upperBound - start))
        return Self.plainInlineText(label)
    }

    /// Strips the light markdown that commonly decorates a task label so the
    /// panel reads like the document without the `**`/`` ` `` scaffolding.
    private static func plainInlineText(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = trimmed.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        text = text.replacingOccurrences(of: "*", with: "")
        text = text.replacingOccurrences(of: "`", with: "")
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func outline(_ blocks: [MDBlock], root: MDBlock, map: SourceMap) -> [HeadingNode] {
        var nodes: [HeadingNode] = []
        var slugs: [String: Int] = [:]
        guard !blocks.isEmpty else { return [] }

        // A section runs until the next heading at the same level or above.
        // Found for every heading in O(H) with a monotonic stack, instead of a
        // per-heading forward scan over the rest of the list (O(H²)).
        var sectionEnds = [Int](repeating: map.length, count: blocks.count)
        var stack: [(level: Int, lineStart: Int)] = []
        for index in blocks.indices.reversed() {
            guard case .heading(let level) = blocks[index].content else { continue }
            while let top = stack.last, top.level > level { stack.removeLast() }
            sectionEnds[index] = stack.last?.lineStart ?? map.length
            stack.append((
                level: level,
                lineStart: map.text.lineStart(before: blocks[index].range.location)
            ))
        }

        // Each heading's own-prose word count (subsections excluded) is derived
        // in one tree walk, not one walk per heading.
        var spans: [NSRange] = []
        spans.reserveCapacity(blocks.count)
        for (index, block) in blocks.enumerated() {
            let ownEnd = index + 1 < blocks.count
                ? map.text.lineStart(before: blocks[index + 1].range.location)
                : map.length
            spans.append(NSRange(
                location: block.range.upperBound,
                length: max(0, ownEnd - block.range.upperBound)
            ))
        }
        let wordCounts = PlainText.prosePerSection(in: root, spans: spans, text: map.text)
            .map { Metrics.wordCount($0) }

        for (index, block) in blocks.enumerated() {
            guard case .heading(let level) = block.content else { continue }
            let lineStart = map.text.lineStart(before: block.range.location)

            let title = PlainText.of(block, in: map.text).trimmingCharacters(in: .whitespacesAndNewlines)
            let base = Slug.make(title)
            let count = slugs[base, default: 0]
            slugs[base] = count + 1

            nodes.append(HeadingNode(
                level: level,
                title: title,
                range: block.range,
                contentRange: block.contentRange,
                sectionRange: NSRange(location: lineStart, length: max(0, sectionEnds[index] - lineStart)),
                parentIndex: nil,
                childIndices: [],
                slug: count == 0 ? base : "\(base)-\(count)",
                wordCount: wordCounts[index]
            ))
        }

        // Parent/child links, resolved once the levels are all known.
        var parentStack: [Int] = []
        for index in nodes.indices {
            while let top = parentStack.last, nodes[top].level >= nodes[index].level { parentStack.removeLast() }
            if let parent = parentStack.last {
                nodes[index].parentIndex = parent
                nodes[parent].childIndices.append(index)
            }
            parentStack.append(index)
        }
        return nodes
    }
}

// MARK: - Slugs

enum Slug {
    /// GitHub's anchor rules: lowercase, drop everything that isn't a letter,
    /// number, space or hyphen, then spaces become hyphens.
    static func make(_ title: String) -> String {
        var out = ""
        for character in title.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
            } else if character == " " || character == "-" || character == "_" {
                out.append("-")
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}
