import Foundation

// MARK: - YAML front matter (§4.1)
//
// This runs *before* cmark sees the text and the body is parsed without it.
// That is not an optimisation: `---` on line 1 followed by `title: X` parses as
// a thematic break plus a setext H2, which is both wrong and would shift every
// range after it.
//
// This is a metadata card, not a YAML engine.  It handles scalars, quoted
// strings, inline `[a, b]` lists and block sequences, and silently ignores
// anything else rather than failing — a document with exotic YAML should still
// open, it just gets fewer fields in its card (§5.1).

enum FrontMatterScanner {
    /// Detects front matter, which is only front matter when `---` is the very
    /// first line of the file.
    static func scan(_ map: SourceMap) -> FrontMatter? {
        guard map.lineCount > 1 else { return nil }
        guard isFence(map.string(ofLine: 0), opening: true) else { return nil }

        var closing: Int? = nil
        for line in 1..<map.lineCount where isFence(map.string(ofLine: line), opening: false) {
            closing = line
            break
        }
        guard let closingLine = closing else { return nil }

        let bodyStart = map.lineStarts[1]
        let bodyEnd = map.lineStarts[closingLine]
        let range = NSRange(
            location: 0,
            length: map.fullRange(ofLine: closingLine).upperBound
        )
        let bodyRange = NSRange(location: bodyStart, length: max(0, bodyEnd - bodyStart))
        let fields = parseFields(map, from: 1, to: closingLine)
        return FrontMatter(fields: fields, range: range, bodyRange: bodyRange)
    }

    private static func isFence(_ line: String, opening: Bool) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "---" || (!opening && trimmed == "...")
    }

    private static func parseFields(_ map: SourceMap, from: Int, to: Int) -> [FrontMatterField] {
        var fields: [FrontMatterField] = []
        var line = from
        while line < to {
            let text = map.string(ofLine: line)
            let lineRange = map.contentRange(ofLine: line)
            defer { line += 1 }

            if text.isBlankLine || text.leadingIndent.count != 0 { continue }
            if text.hasPrefix("#") { continue }
            guard let colon = text.firstIndex(of: ":") else { continue }

            let key = String(text[text.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.allSatisfy(isKeyCharacter) else { continue }

            let rawValue = String(text[text.index(after: colon)...])
            let keyRange = NSRange(location: lineRange.location, length: key.utf16.count)
            let valueStart = lineRange.location + text.utf16.count - rawValue.utf16.count
            let trimmedValue = rawValue.trimmingCharacters(in: .whitespaces)

            // `key: |` and `key: >` YAML block scalars span following indented
            // lines.  A card is not a YAML engine, but a block scalar whose
            // value was read as the literal "|" or ">" rendered the card
            // wrong, so the continuation lines are folded into the value.
            if isBlockScalarIndicator(trimmedValue) {
                let style = trimmedValue.contains(">") ? BlockScalarStyle.folded : .literal
                let (parts, consumed) = blockScalar(map, startingAt: line + 1, limit: to)
                if !parts.isEmpty {
                    let end = map.contentRange(ofLine: line + consumed).upperBound
                    let value = style == .literal
                        ? parts.joined(separator: "\n")
                        : parts.joined(separator: " ")
                    fields.append(FrontMatterField(
                        key: key, value: value, keyRange: keyRange,
                        valueRange: NSRange(location: valueStart, length: max(0, end - valueStart))
                    ))
                    line += consumed
                }
                continue
            }

            if trimmedValue.isEmpty {
                // `tags:` followed by an indented `- a` block sequence.
                let (items, consumed) = blockSequence(map, startingAt: line + 1, limit: to)
                if !items.isEmpty {
                    let end = map.contentRange(ofLine: line + consumed).upperBound
                    fields.append(FrontMatterField(
                        key: key, value: items.joined(separator: ", "),
                        keyRange: keyRange,
                        valueRange: NSRange(location: valueStart, length: max(0, end - valueStart))
                    ))
                    line += consumed
                }
                continue
            }

            let valueRange = NSRange(location: valueStart, length: rawValue.utf16.count)
            fields.append(FrontMatterField(
                key: key, value: normalise(trimmedValue), keyRange: keyRange, valueRange: valueRange
            ))
        }
        return fields
    }

    private static func isKeyCharacter(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == "." || ch == " "
    }

    private enum BlockScalarStyle {
        case literal   // `|`: newlines kept
        case folded    // `>`: continuation lines folded on spaces
    }

    private static func isBlockScalarIndicator(_ value: String) -> Bool {
        let indicator = value.filter { $0 == "|" || $0 == ">" }
        guard indicator.count == 1, value.allSatisfy({ $0 == "|" || $0 == ">" || $0 == "-" || $0 == "+" }) else {
            return false
        }
        return value == "|" || value == ">" || value == "|-" || value == ">-"
            || value == "|+" || value == ">+"
    }

    /// Consumes the indented (or blank) lines that make up a block scalar,
    /// returning the folded content lines and how many lines were consumed.
    private static func blockScalar(
        _ map: SourceMap, startingAt start: Int, limit: Int
    ) -> ([String], Int) {
        var parts: [String] = []
        var line = start
        while line < limit {
            let text = map.string(ofLine: line)
            if text.isBlankLine { line += 1; continue }
            guard !text.leadingIndent.isEmpty else { break }
            parts.append(String(text.dropFirst(text.leadingIndent.count)).trimmingCharacters(in: .whitespacesAndNewlines))
            line += 1
        }
        return (parts, line - start)
    }

    /// Consumes `  - item` lines, returning the items and how many lines they took.
    private static func blockSequence(_ map: SourceMap, startingAt start: Int, limit: Int) -> ([String], Int) {
        var items: [String] = []
        var line = start
        while line < limit {
            let text = map.string(ofLine: line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !text.leadingIndent.isEmpty, trimmed.hasPrefix("- ") || trimmed == "-" else { break }
            items.append(normalise(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            line += 1
        }
        return (items, line - start)
    }

    /// Unquotes scalars and flattens inline `[a, b]` lists to `a, b`.
    private static func normalise(_ value: String) -> String {
        var v = value
        if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        } else if v.hasPrefix("["), v.hasSuffix("]") {
            let inner = String(v.dropFirst().dropLast())
            v = inner
                .split(separator: ",")
                .map { normalise($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }
        return v
    }
}
