import Foundation

/// Values that can be written by the small, source-preserving front matter
/// editor.  This is intentionally not a YAML value tree.  Complex YAML stays
/// in Source mode, where it cannot be changed by an incomplete model.
public enum FrontMatterValue: Equatable, Sendable {
    case text(String)
    case boolean(Bool)
    case number(Double)
    case list([String])

    public static func string(_ value: String) -> Self { .text(value) }
}

public enum FrontMatterEditOperation: Sendable {
    case set(key: String, value: FrontMatterValue)
    case add(key: String, value: FrontMatterValue)
    case remove(key: String)
}

public enum FrontMatterSourceFallback: String, Error, Equatable, Sendable {
    case missingFrontMatter
    case malformedFence
    case nestedYAML
    case commentsNotSupported
    case anchorsOrAliasesNotSupported
    case blockScalarNotSupported
    case ambiguousField
    case unsupportedValue
    case invalidSourceRange
    case sourceChanged
}

/// One source-local front matter edit.  `expected` prevents an old card from
/// changing a newer buffer.  Callers can apply the proposal as one undo step.
public struct FrontMatterEditProposal: Sendable {
    public let range: NSRange
    public let replacement: String
    public let summary: String
    public let expected: String

    public init(range: NSRange, replacement: String, summary: String, expected: String) {
        self.range = range
        self.replacement = replacement
        self.summary = summary
        self.expected = expected
    }

    public var edit: TextEdit {
        TextEdit(range: range, replacement: replacement, summary: summary)
    }

    public func applying(to source: String) -> String? {
        let ns = source as NSString
        guard range.location >= 0, range.upperBound <= ns.length,
              ns.substring(with: range) == expected else { return nil }
        let output = NSMutableString(string: source)
        output.replaceCharacters(in: range, with: replacement)
        return output as String
    }
}

public struct FrontMatterEditResult: Sendable {
    public let proposal: FrontMatterEditProposal?
    public let fallback: FrontMatterSourceFallback?

    public init(proposal: FrontMatterEditProposal?, fallback: FrontMatterSourceFallback? = nil) {
        self.proposal = proposal
        self.fallback = fallback
    }
}

public enum FrontMatterEditing {
    public static func propose(
        _ document: ParsedDocument,
        operation: FrontMatterEditOperation
    ) -> FrontMatterEditResult {
        guard let front = document.frontMatter else {
            let opening = document.range(ofLine: 1)
            return FrontMatterEditResult(
                proposal: nil,
                fallback: opening.length > 0 && document.substring(opening).trimmingCharacters(in: .whitespaces) == "---"
                    ? .malformedFence : .missingFrontMatter
            )
        }

        guard let failure = validate(document: document, frontMatter: front) else {
            return make(document, frontMatter: front, operation: operation)
        }
        return FrontMatterEditResult(proposal: nil, fallback: failure)
    }

    public static func proposal(
        _ document: ParsedDocument,
        operation: FrontMatterEditOperation
    ) -> FrontMatterEditProposal? {
        propose(document, operation: operation).proposal
    }

    public static func set(
        _ document: ParsedDocument, key: String, value: FrontMatterValue
    ) -> FrontMatterEditResult {
        propose(document, operation: .set(key: key, value: value))
    }

    public static func add(
        _ document: ParsedDocument, key: String, value: FrontMatterValue
    ) -> FrontMatterEditResult {
        propose(document, operation: .add(key: key, value: value))
    }

    public static func remove(
        _ document: ParsedDocument, key: String
    ) -> FrontMatterEditResult {
        propose(document, operation: .remove(key: key))
    }

    private static func make(
        _ document: ParsedDocument,
        frontMatter: FrontMatter,
        operation: FrontMatterEditOperation
    ) -> FrontMatterEditResult {
        let key: String
        switch operation {
        case let .set(name, _), let .add(name, _), let .remove(name): key = name
        }
        guard isSimpleKey(key) else { return FrontMatterEditResult(proposal: nil, fallback: .unsupportedValue) }
        var matches = frontMatter.fields.filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }
        if matches.isEmpty, let empty = emptyField(named: key, in: document, frontMatter: frontMatter) {
            matches = [empty]
        }
        if matches.count > 1 { return FrontMatterEditResult(proposal: nil, fallback: .ambiguousField) }

        switch operation {
        case let .set(_, value):
            guard let field = matches.first else {
                return makeAdd(document, frontMatter: frontMatter, key: key, value: value)
            }
            let raw = document.substring(field.valueRange)
            guard let rendered = render(value, preserving: raw) else {
                return FrontMatterEditResult(proposal: nil, fallback: .unsupportedValue)
            }
            return result(document, range: field.valueRange, replacement: rendered, summary: "Set " + field.key)
        case let .add(_, value):
            guard matches.isEmpty else { return FrontMatterEditResult(proposal: nil, fallback: .ambiguousField) }
            return makeAdd(document, frontMatter: frontMatter, key: key, value: value)
        case .remove:
            guard let field = matches.first else { return FrontMatterEditResult(proposal: nil, fallback: .ambiguousField) }
            let ns = document.text as NSString
            let start = ns.lineStart(before: field.keyRange.location)
            let end = ns.lineEnd(after: field.valueRange.upperBound)
            let range = NSRange(location: start, length: end - start)
            return result(document, range: range, replacement: "", summary: "Remove " + field.key)
        }
    }

    private static func makeAdd(
        _ document: ParsedDocument,
        frontMatter: FrontMatter,
        key: String,
        value: FrontMatterValue
    ) -> FrontMatterEditResult {
        guard let rendered = render(value, preserving: "") else {
            return FrontMatterEditResult(proposal: nil, fallback: .unsupportedValue)
        }
        let newline = lineEnding(in: document.substring(frontMatter.range))
        let insertion = key + ": " + rendered + newline
        let range = NSRange(location: frontMatter.bodyRange.upperBound, length: 0)
        return result(document, range: range, replacement: insertion, summary: "Add " + key)
    }

    private static func result(
        _ document: ParsedDocument, range: NSRange, replacement: String, summary: String
    ) -> FrontMatterEditResult {
        let ns = document.text as NSString
        guard range.location >= 0, range.upperBound <= ns.length else {
            return FrontMatterEditResult(proposal: nil, fallback: .invalidSourceRange)
        }
        return FrontMatterEditResult(
            proposal: FrontMatterEditProposal(
                range: range, replacement: replacement,
                summary: summary, expected: ns.substring(with: range)
            )
        )
    }

    private static func validate(
        document: ParsedDocument, frontMatter: FrontMatter
    ) -> FrontMatterSourceFallback? {
        let source = document.substring(frontMatter.bodyRange)
        let lines = source.components(separatedBy: .newlines)
        var keys = Set<String>()
        for line in lines {
            if line.isEmpty { continue }
            if line.first?.isWhitespace == true { return .nestedYAML }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { return .commentsNotSupported }
            if trimmed.contains("&") || trimmed.contains("*") { return .anchorsOrAliasesNotSupported }
            if let colon = trimmed.firstIndex(of: ":") {
                let raw = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if raw == "|" || raw == ">" || raw.hasPrefix("| ") || raw.hasPrefix("> ") {
                    return .blockScalarNotSupported
                }
                let name = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                guard isSimpleKey(name) else { return .unsupportedValue }
                let folded = name.lowercased()
                guard keys.insert(folded).inserted else { return .ambiguousField }
            } else {
                return .unsupportedValue
            }
        }
        return nil
    }

    private static func isSimpleKey(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." || $0 == " " }
    }

    private static func render(_ value: FrontMatterValue, preserving raw: String) -> String? {
        let characters = Array(raw)
        let leftCount = characters.prefix { $0.isWhitespace }.count
        let rightCount = characters.dropFirst(leftCount).reversed().prefix { $0.isWhitespace }.count
        let safeRightCount = min(rightCount, max(0, characters.count - leftCount))
        let leading = String(characters.prefix(leftCount))
        let trailing = safeRightCount == 0 ? "" : String(characters.suffix(safeRightCount))
        let tokenEnd = max(leftCount, characters.count - safeRightCount)
        let token = String(characters[leftCount..<tokenEnd])
        let rendered: String
        switch value {
        case let .text(text):
            if token.first == "\"" && token.last == "\"" {
                rendered = doubleQuoted(text)
            } else if token.first == "'" && token.last == "'" {
                rendered = "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
            } else if needsQuote(text) {
                rendered = doubleQuoted(text)
            } else { rendered = text }
        case let .boolean(value): rendered = value ? "true" : "false"
        case let .number(value):
            guard value.isFinite else { return nil }
            if value.rounded() == value, abs(value) <= Double(Int64.max) {
                rendered = String(Int64(value))
            } else {
                rendered = String(value)
            }
        case let .list(items):
            rendered = "[" + items.map { item in
                needsQuote(item) ? doubleQuoted(item) : item
            }.joined(separator: ", ") + "]"
        }
        return leading + rendered + trailing
    }

    private static func doubleQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func needsQuote(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        guard text.first?.isWhitespace != true, text.last?.isWhitespace != true else { return true }
        let lower = text.lowercased()
        if ["true", "false", "yes", "no", "null", "~"].contains(lower) { return true }
        if Double(text) != nil { return true }
        if text.contains(where: { ":#[]{}&,*!%@`".contains($0) }) { return true }
        return text.hasPrefix("-") || text.hasPrefix("?")
    }

    private static func lineEnding(in source: String) -> String {
        if source.contains("\r\n") { return "\r\n" }
        if source.contains("\r") { return "\r" }
        return "\n"
    }

    private static func emptyField(
        named key: String, in document: ParsedDocument, frontMatter: FrontMatter
    ) -> FrontMatterField? {
        let ns = document.text as NSString
        var line = document.line(at: frontMatter.bodyRange.location)
        while line <= document.line(at: max(frontMatter.bodyRange.location, frontMatter.bodyRange.upperBound - 1)) {
            let range = document.range(ofLine: line)
            guard range.location >= frontMatter.bodyRange.location,
                  range.location < frontMatter.bodyRange.upperBound else { break }
            let text = ns.substring(with: range)
            guard let colon = text.firstIndex(of: ":") else { line += 1; continue }
            let name = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
            let raw = String(text[text.index(after: colon)...])
            if name.caseInsensitiveCompare(key) == .orderedSame,
               raw.trimmingCharacters(in: .whitespaces).isEmpty {
                let colonOffset = text[..<colon].utf16.count
                let valueRange = NSRange(location: range.location + colonOffset + 1, length: raw.utf16.count)
                return FrontMatterField(
                    key: name,
                    value: "",
                    keyRange: NSRange(location: range.location, length: name.utf16.count),
                    valueRange: valueRange
                )
            }
            line += 1
        }
        return nil
    }
}
