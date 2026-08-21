import Foundation

/// The deliberately small HTML vocabulary that Downright may present as
/// document content.  This is a source annotation, not an HTML DOM: every
/// range points back into the original buffer so editing and copying remain
/// lossless.
public enum SafeHTMLKind: Sendable, Equatable {
    case paragraph(align: SafeHTMLAlignment?)
    case heading(level: Int)
    case strong
    case emphasis
    case link(destination: String, title: String?)
    case image(source: String, alt: String)
    /// A recognized but deliberately non-rendered tag, such as a remote image.
    /// Its source remains visible and no network or file access is attempted.
    case inert
    case lineBreak
    case details(open: Bool)
    /// A closing `</details>` emitted in a separate Markdown HTML block. The
    /// parser accepts this boundary fragment so the opening disclosure can
    /// remain source-addressed and native-rendered without treating malformed
    /// or executable HTML as safe.
    case detailsClosing
    case summary
    case table
    case tableRow
    case tableCell(header: Bool, align: SafeHTMLAlignment?)
}

public enum SafeHTMLAlignment: String, Sendable, Equatable {
    case left, center, right, justify
}

public struct SafeHTMLAnnotation: Sendable, Equatable {
    public let kind: SafeHTMLKind
    /// The complete element, including its opening and closing tags.
    public let range: NSRange
    /// The content between an element's tags. Void elements have an empty
    /// range immediately after their tag.
    public let contentRange: NSRange
    /// Opening and closing tag source ranges. These are the only characters
    /// the presentation layer may omit; element content is never synthesized.
    public let tagRanges: [NSRange]

    public init(kind: SafeHTMLKind, range: NSRange, contentRange: NSRange, tagRanges: [NSRange]) {
        self.kind = kind
        self.range = range
        self.contentRange = contentRange
        self.tagRanges = tagRanges
    }
}

public struct SafeHTMLDocument: Sendable, Equatable {
    public let range: NSRange
    public let annotations: [SafeHTMLAnnotation]
    /// `false` means the complete source range must remain literal. No partial
    /// sanitisation is attempted, which prevents a safe-looking child from
    /// hiding an executable or unknown parent.
    public let isSafe: Bool

    public init(range: NSRange, annotations: [SafeHTMLAnnotation], isSafe: Bool) {
        self.range = range
        self.annotations = annotations
        self.isSafe = isSafe
    }

    public var tagRanges: [NSRange] {
        annotations.flatMap(\.tagRanges).sorted { $0.location < $1.location }
    }

    public var hiddenTagRanges: [NSRange] { tagRanges }
}

/// A conservative, non-executing parser for README-style presentational HTML.
///
/// It intentionally rejects unknown tags, event attributes, CSS/script/style,
/// malformed nesting, and risky URL schemes. Rejection returns a document
/// marked unsafe so callers can render the original bytes as inert literal
/// text. This is not used by HTML export, whose safety rules remain separate.
public enum SafeHTMLParser {
    public static func parse(_ text: String, range: NSRange? = nil) -> SafeHTMLDocument? {
        let source = text as NSString
        let bounds = range ?? NSRange(location: 0, length: source.length)
        guard bounds.location >= 0, bounds.length > 0, bounds.upperBound <= source.length else { return nil }
        guard source.substring(with: bounds).contains("<") else { return nil }

        var parser = Parser(source: source, bounds: bounds)
        return parser.parse()
    }

    private struct OpenElement {
        let name: String
        let range: NSRange
        let contentStart: Int
        let tagRange: NSRange
        let kind: SafeHTMLKind
        let attributes: [String: String]
    }

    private struct Parser {
        let source: NSString
        let bounds: NSRange
        var cursor: Int
        var stack: [OpenElement] = []
        var annotations: [SafeHTMLAnnotation] = []
        var sawTag = false
        var rejected = false

        init(source: NSString, bounds: NSRange) {
            self.source = source
            self.bounds = bounds
            self.cursor = bounds.location
        }

        mutating func parse() -> SafeHTMLDocument {
            while cursor < bounds.upperBound, !rejected {
                guard let opening = nextTag() else { break }
                if opening.isCommentOrDeclaration { rejected = true; break }
                sawTag = true
                if opening.isClosing {
                    close(opening)
                } else {
                    open(opening)
                }
            }
            if cursor < bounds.upperBound, !source.substring(with: NSRange(location: cursor, length: bounds.upperBound - cursor))
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                // Text is fine; only a non-tag `<` is malformed.
                if source.substring(with: NSRange(location: cursor, length: bounds.upperBound - cursor)).contains("<") {
                    rejected = true
                }
            }
            if !stack.isEmpty {
                // swift-markdown may split a README-style details element at
                // blank Markdown lines: the opening block ends with a
                // complete `<details>` tree but its closing tag is emitted in
                // a later HTML block. Keep that known, inert container
                // source-addressed across the boundary. Any other open stack
                // remains malformed and therefore literal.
                if stack.count == 1, stack[0].name == "details",
                   hasClosingDetails(after: bounds.upperBound) {
                    let open = stack.removeLast()
                    annotations.append(SafeHTMLAnnotation(
                        kind: open.kind,
                        range: open.tagRange,
                        contentRange: NSRange(location: open.tagRange.upperBound, length: 0),
                        tagRanges: [open.tagRange]
                    ))
                } else {
                    rejected = true
                }
            }
            return SafeHTMLDocument(range: bounds, annotations: rejected ? [] : annotations.sorted { $0.range.location < $1.range.location }, isSafe: sawTag && !rejected)
        }

        private struct Tag {
            let name: String
            let attributes: [String: String]
            let range: NSRange
            let isClosing: Bool
            let isSelfClosing: Bool
            let isCommentOrDeclaration: Bool
        }

        private mutating func nextTag() -> Tag? {
            guard let start = index(of: "<", from: cursor) else {
                cursor = bounds.upperBound
                return nil
            }
            if start > cursor {
                let text = source.substring(with: NSRange(location: cursor, length: start - cursor))
                if text.contains("<") { rejected = true; return nil }
            }
            guard let end = tagEnd(from: start) else { rejected = true; return nil }
            let tagRange = NSRange(location: start, length: end - start + 1)
            let raw = source.substring(with: NSRange(location: start + 1, length: end - start - 1))
            cursor = end + 1
            if raw.hasPrefix("!") || raw.hasPrefix("?") || raw.hasPrefix("/") && raw.dropFirst().first == "!" {
                return Tag(name: "", attributes: [:], range: tagRange, isClosing: false, isSelfClosing: false, isCommentOrDeclaration: true)
            }
            let closing = raw.first == "/"
            let body = closing ? String(raw.dropFirst()) : raw
            let selfClosing = !closing && body.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/")
            let cleaned = selfClosing ? String(body.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) : body
            guard let nameEnd = cleaned.firstIndex(where: { $0.isWhitespace }) else {
                let name = cleaned.lowercased()
                guard allowedNames.contains(name) else { rejected = true; return nil }
                return Tag(name: name, attributes: [:], range: tagRange, isClosing: closing, isSelfClosing: selfClosing, isCommentOrDeclaration: false)
            }
            let name = String(cleaned[..<nameEnd]).lowercased()
            guard allowedNames.contains(name) else { rejected = true; return nil }
            let rest = String(cleaned[nameEnd...])
            guard !closing, let attrs = attributes(in: rest, for: name) else {
                if closing && rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return Tag(name: name, attributes: [:], range: tagRange, isClosing: true, isSelfClosing: false, isCommentOrDeclaration: false)
                }
                rejected = true
                return nil
            }
            return Tag(name: name, attributes: attrs, range: tagRange, isClosing: false, isSelfClosing: selfClosing, isCommentOrDeclaration: false)
        }

        private mutating func open(_ tag: Tag) {
            guard let kind = kind(for: tag.name, attributes: tag.attributes) else { rejected = true; return }
            let void = tag.name == "br" || tag.name == "img"
            guard !void || tag.isSelfClosing || tag.name == "br" || tag.name == "img" else { rejected = true; return }
            if void {
                annotations.append(SafeHTMLAnnotation(kind: kind, range: tag.range,
                                                      contentRange: NSRange(location: tag.range.upperBound, length: 0),
                                                      tagRanges: [tag.range]))
                return
            }
            guard !tag.isSelfClosing else { rejected = true; return }
            stack.append(OpenElement(name: tag.name, range: NSRange(location: tag.range.location, length: 0),
                                     contentStart: tag.range.upperBound, tagRange: tag.range, kind: kind,
                                     attributes: tag.attributes))
        }

        private mutating func close(_ tag: Tag) {
            guard let open = stack.popLast(), open.name == tag.name else {
                // The matching opening tag can live in the preceding
                // HTMLBlock when Markdown contains a blank line inside
                // `<details>`. This fragment is safe only for that inert
                // container; unknown/unbalanced tags stay literal.
                if stack.isEmpty, tag.name == "details",
                   hasOpeningDetails(before: bounds.location) {
                    annotations.append(SafeHTMLAnnotation(
                        kind: .detailsClosing,
                        range: tag.range,
                        contentRange: NSRange(location: tag.range.location, length: 0),
                        tagRanges: [tag.range]
                    ))
                } else {
                    rejected = true
                }
                return
            }
            let elementRange = NSRange(location: open.tagRange.location, length: tag.range.upperBound - open.tagRange.location)
            let content = NSRange(location: open.contentStart, length: max(0, tag.range.location - open.contentStart))
            annotations.append(SafeHTMLAnnotation(kind: open.kind, range: elementRange, contentRange: content,
                                                   tagRanges: [open.tagRange, tag.range]))
        }

        private func tagEnd(from start: Int) -> Int? {
            var quote: unichar = 0
            var index = start + 1
            while index < bounds.upperBound {
                let character = source.character(at: index)
                if quote != 0 {
                    if character == quote { quote = 0 }
                } else if character == 0x22 || character == 0x27 {
                    quote = character
                } else if character == 0x3E {
                    return index
                }
                index += 1
            }
            return nil
        }

        /// True when the genuine closing fragment appears after `location`.
        ///
        /// swift-markdown splits a README-style `<details>` element at blank
        /// lines, so the partner tag lives in a *later HTML block*. A bare
        /// substring search over the whole source would let any mention of
        /// the text satisfy that check — `` `<details>` `` inside a code span,
        /// or prose naming the element — and hide a stray literal
        /// `</details>` that was never part of a real element. Genuine
        /// partners are written as their own HTML block, so require that
        /// shape: at most three spaces of indent on the line, then the tag.
        private func hasClosingDetails(after location: Int) -> Bool {
            guard location < source.length else { return false }
            var search = NSRange(location: location, length: source.length - location)
            while search.length > 0 {
                let match = source.range(
                    of: "</details>",
                    options: [.caseInsensitive],
                    range: search
                )
                guard match.location != NSNotFound else { return false }
                if isHTMLBlockLineStart(match.location) {
                    return true
                }
                search = NSRange(
                    location: match.location + 1,
                    length: source.length - (match.location + 1)
                )
            }
            return false
        }

        /// True when a real `<details …>` opening tag appears before
        /// `location`, written as an HTML block. See `hasClosingDetails` for
        /// why the search is anchored to the block shape rather than run over
        /// raw source.
        private func hasOpeningDetails(before location: Int) -> Bool {
            guard location > 0 else { return false }
            var search = NSRange(location: 0, length: location)
            while search.length > 0 {
                let match = source.range(
                    of: "<details",
                    options: [.caseInsensitive, .backwards],
                    range: search
                )
                guard match.location != NSNotFound else { return false }
                // The partner must live entirely before this block.
                guard match.upperBound < location else {
                    search.length = match.location
                    continue
                }
                if isHTMLBlockLineStart(match.location) {
                    let next = source.character(at: match.upperBound)
                    if next == 0x3E || next == 0x20 || next == 0x09 || next == 0x0A || next == 0x0D {
                        return true
                    }
                }
                search.length = match.location
            }
            return false
        }

        /// Whether `location` starts an HTML block line: beginning of source
        /// or right after a newline, with no more than three leading spaces
        /// (CommonMark's HTML-block indentation allowance). Tabs fail
        /// deliberately: real emitters indent blocks with spaces, while code
        /// fences routinely indent deeper than three.
        private func isHTMLBlockLineStart(_ location: Int) -> Bool {
            var index = location
            var spaces = 0
            while index > 0 {
                let previous = source.character(at: index - 1)
                if previous == 0x20 {
                    spaces += 1
                    index -= 1
                    if spaces > 3 { return false }
                    continue
                }
                return previous == 0x0A || previous == 0x0D
            }
            return true
        }

        private func index(of character: Character, from start: Int) -> Int? {
            let target = unichar(character.asciiValue ?? 0)
            guard target != 0 else { return nil }
            for index in start..<bounds.upperBound where source.character(at: index) == target { return index }
            return nil
        }
    }

    private static let allowedNames: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "strong", "b", "em", "i", "a", "img", "br", "details", "summary", "table", "thead", "tbody", "tr", "th", "td"]

    private static func attributes(in raw: String, for name: String) -> [String: String]? {
        var result: [String: String] = [:]
        var index = raw.startIndex
        while index < raw.endIndex {
            while index < raw.endIndex, raw[index].isWhitespace { index = raw.index(after: index) }
            guard index < raw.endIndex else { break }
            let start = index
            while index < raw.endIndex, !raw[index].isWhitespace, raw[index] != "=" { index = raw.index(after: index) }
            let key = String(raw[start..<index]).lowercased()
            guard !key.isEmpty, !key.hasPrefix("on") else { return nil }
            while index < raw.endIndex, raw[index].isWhitespace { index = raw.index(after: index) }
            if name == "details", key == "open",
               (index == raw.endIndex || raw[index] != "=") {
                result[key] = ""
                continue
            }
            guard index < raw.endIndex, raw[index] == "=" else { return nil }
            index = raw.index(after: index)
            while index < raw.endIndex, raw[index].isWhitespace { index = raw.index(after: index) }
            guard index < raw.endIndex else { return nil }
            let quote = raw[index]
            guard quote == "\"" || quote == "'" else { return nil }
            index = raw.index(after: index)
            let valueStart = index
            while index < raw.endIndex, raw[index] != quote { index = raw.index(after: index) }
            guard index < raw.endIndex else { return nil }
            let value = String(raw[valueStart..<index])
            index = raw.index(after: index)
            guard allowedAttribute(key, for: name),
                  (name == "img" && key == "src" || safeURL(value, for: key, tag: name))
            else { return nil }
            result[key] = value
        }
        return result
    }

    private static func allowedAttribute(_ key: String, for tag: String) -> Bool {
        switch tag {
        case "p", "h1", "h2", "h3", "h4", "h5", "h6", "th", "td": return key == "align"
        case "a": return key == "href" || key == "title"
        case "img": return key == "src" || key == "alt" || key == "title"
        case "details": return key == "open"
        default: return false
        }
    }

    private static func safeURL(_ value: String, for key: String, tag: String) -> Bool {
        guard key == "href" || key == "src" else { return true }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.contains(":") || value.hasPrefix("https:") || value.hasPrefix("http:") || value.hasPrefix("mailto:") || value.hasPrefix("#") else { return false }
        if key == "src" {
            return !value.hasPrefix("http:") && !value.hasPrefix("https:") && !value.hasPrefix("//") && !value.hasPrefix("/") && !value.hasPrefix("file:") && !value.hasPrefix("data:")
        }
        return !value.hasPrefix("javascript:") && !value.hasPrefix("data:") && !value.hasPrefix("vbscript:")
    }

    private static func kind(for name: String, attributes: [String: String]) -> SafeHTMLKind? {
        let alignment = attributes["align"]
            .map { $0.lowercased() }
            .flatMap(SafeHTMLAlignment.init(rawValue:))
        switch name {
        case "p": return .paragraph(align: alignment)
        case "h1", "h2", "h3", "h4", "h5", "h6": return .heading(level: Int(name.dropFirst()) ?? 1)
        case "strong", "b": return .strong
        case "em", "i": return .emphasis
        case "a": guard let href = attributes["href"] else { return nil }; return .link(destination: href, title: attributes["title"])
        case "img":
            guard let src = attributes["src"] else { return nil }
            guard safeLocalImageSource(src) else { return .inert }
            return .image(source: src, alt: attributes["alt"] ?? "")
        case "br": return .lineBreak
        case "details": return .details(open: attributes["open"] != nil)
        case "summary": return .summary
        case "table", "thead", "tbody": return .table
        case "tr": return .tableRow
        case "th": return .tableCell(header: true, align: alignment)
        case "td": return .tableCell(header: false, align: alignment)
        default: return nil
        }
    }

    private static func safeLocalImageSource(_ source: String) -> Bool {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !value.isEmpty
            && !value.hasPrefix("http:")
            && !value.hasPrefix("https:")
            && !value.hasPrefix("//")
            && !value.hasPrefix("/")
            && !value.hasPrefix("file:")
            && !value.hasPrefix("data:")
            && !value.contains("..")
    }
}
