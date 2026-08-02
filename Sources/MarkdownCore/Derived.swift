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
        var line = 0
        var fence: String?
        while line < map.lineCount {
            defer { line += 1 }
            let text = map.string(ofLine: line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)

            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") { fence = "```"; continue }
            if trimmed.hasPrefix("~~~") { fence = "~~~"; continue }
            guard text.indentColumns < 4, trimmed.hasPrefix("[") else { continue }

            guard let close = closingBracket(trimmed),
                  trimmed.index(after: close) < trimmed.endIndex,
                  trimmed[trimmed.index(after: close)] == ":"
            else { continue }

            let label = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            guard !label.isEmpty else { continue }
            let lineRange = map.contentRange(ofLine: line)
            let markerLength = trimmed.distance(from: trimmed.startIndex, to: close) + 2
            let indent = text.utf16.count - trimmed.utf16.count == 0 ? 0 : text.leadingIndent.utf16.count
            let bodyStart = lineRange.location + indent + markerLength
            let body = String(trimmed[trimmed.index(close, offsetBy: 2)...])

            if label.hasPrefix("^") {
                let identifier = String(label.dropFirst())
                guard !identifier.isEmpty else { continue }
                var last = line
                while last + 1 < map.lineCount {
                    let next = map.string(ofLine: last + 1)
                    guard !next.isBlankLine, next.indentColumns >= 4 || next.hasPrefix("\t") else { break }
                    last += 1
                }
                let end = map.contentRange(ofLine: last).upperBound
                let leadingSpace = body.hasPrefix(" ") ? 1 : 0
                footnoteDefinitions.append(FootnoteDefinition(
                    identifier: identifier,
                    markerRange: NSRange(
                        location: lineRange.location,
                        length: bodyStart + leadingSpace - lineRange.location
                    ),
                    range: NSRange(location: lineRange.location, length: max(0, end - lineRange.location))
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

    private func closingBracket(_ text: String) -> String.Index? {
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            switch text[index] {
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { return index }
            case "\\": index = text.index(after: index)
            default: break
            }
            guard index < text.endIndex else { break }
            index = text.index(after: index)
        }
        return nil
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
                text: PlainText.of(block, in: map.text).trimmingCharacters(in: .whitespacesAndNewlines),
                headingIndex: headings.lastIndex { $0.range.location < block.range.location },
                indentLevel: indent
            )
        }
    }

    private static func outline(_ blocks: [MDBlock], root: MDBlock, map: SourceMap) -> [HeadingNode] {
        var nodes: [HeadingNode] = []
        var slugs: [String: Int] = [:]

        for (index, block) in blocks.enumerated() {
            guard case .heading(let level) = block.content else { continue }
            let lineStart = map.text.lineStart(before: block.range.location)

            // A section runs until the next heading at the same level or above.
            var sectionEnd = map.length
            for next in blocks[(index + 1)...] {
                guard case .heading(let nextLevel) = next.content else { continue }
                if nextLevel <= level {
                    sectionEnd = map.text.lineStart(before: next.range.location)
                    break
                }
            }
            // Its own prose stops at the next heading of any level.
            let ownEnd = index + 1 < blocks.count
                ? map.text.lineStart(before: blocks[index + 1].range.location)
                : map.length

            let title = PlainText.of(block, in: map.text).trimmingCharacters(in: .whitespacesAndNewlines)
            let base = Slug.make(title)
            let count = slugs[base, default: 0]
            slugs[base] = count + 1

            let ownRange = NSRange(
                location: block.range.upperBound,
                length: max(0, ownEnd - block.range.upperBound)
            )
            nodes.append(HeadingNode(
                level: level,
                title: title,
                range: block.range,
                contentRange: block.contentRange,
                sectionRange: NSRange(location: lineStart, length: max(0, sectionEnd - lineStart)),
                parentIndex: nil,
                childIndices: [],
                slug: count == 0 ? base : "\(base)-\(count)",
                wordCount: Metrics.wordCount(PlainText.prose(in: root, range: ownRange, text: map.text))
            ))
        }

        // Parent/child links, resolved once the levels are all known.
        var stack: [Int] = []
        for index in nodes.indices {
            while let top = stack.last, nodes[top].level >= nodes[index].level { stack.removeLast() }
            if let parent = stack.last {
                nodes[index].parentIndex = parent
                nodes[parent].childIndices.append(index)
            }
            stack.append(index)
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
