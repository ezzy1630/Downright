import Foundation

// MARK: - Positions
//
// Every range in this model is an `NSRange` of UTF-16 offsets into the
// document's `text`.  That is not an implementation detail — it is the contract
// that lets the render layer hand ranges straight to `NSTextStorage` without a
// conversion step, and it is why §3.1 ("raw text is the only source of truth")
// holds all the way down.  Nothing here ever stores a copy of document text
// that could drift from the buffer; content is addressed, not duplicated.

// Foundation already provides `NSRange.union(_:)`; adding one here would make
// every call site ambiguous rather than convenient.
extension NSRange {
    public func contains(offset: Int) -> Bool {
        offset >= location && offset < upperBound
    }

    /// Inclusive of the upper bound — a caret sitting just past the last
    /// character is still "in" the range for reveal purposes (§6.1b).
    public func touches(offset: Int) -> Bool {
        offset >= location && offset <= upperBound
    }

    public var isEmptyRange: Bool { length == 0 }
}

// MARK: - Blocks

public enum CalloutKind: String, Sendable, CaseIterable {
    case note, tip, important, warning, caution, info, success, question, danger, example, quote, abstract, bug, todo

    /// Agents emit these in every casing imaginable.
    public init?(token: String) {
        self.init(rawValue: token.lowercased())
    }
}

public struct Checkbox: Hashable, Sendable {
    public var isChecked: Bool
    /// Range of the single character between the brackets, so a toggle is a
    /// one-character replacement and undo stays trivial.
    public var markRange: NSRange

    public init(isChecked: Bool, markRange: NSRange) {
        self.isChecked = isChecked
        self.markRange = markRange
    }
}

public enum TableAlignment: String, Sendable {
    case none, left, center, right
}

public struct TableCell: Sendable {
    public var range: NSRange
    public var contentRange: NSRange
    public var inlines: [InlineSpan]

    public init(range: NSRange, contentRange: NSRange, inlines: [InlineSpan] = []) {
        self.range = range
        self.contentRange = contentRange
        self.inlines = inlines
    }
}

public struct TableRow: Sendable {
    public var range: NSRange
    public var cells: [TableCell]
    public var isHeader: Bool

    public init(range: NSRange, cells: [TableCell], isHeader: Bool) {
        self.range = range
        self.cells = cells
        self.isHeader = isHeader
    }
}

public struct TableData: Sendable {
    public var rows: [TableRow]
    public var alignments: [TableAlignment]
    /// Range of the `|---|:--:|` delimiter row, which the renderer hides and
    /// the table editor rewrites when alignment changes.
    public var delimiterRange: NSRange

    public init(rows: [TableRow], alignments: [TableAlignment], delimiterRange: NSRange) {
        self.rows = rows
        self.alignments = alignments
        self.delimiterRange = delimiterRange
    }

    public var headerRow: TableRow? { rows.first(where: \.isHeader) }
    public var bodyRows: [TableRow] { rows.filter { !$0.isHeader } }
    public var columnCount: Int { rows.map(\.cells.count).max() ?? 0 }
}

public struct FrontMatterField: Sendable {
    public var key: String
    public var value: String
    public var keyRange: NSRange
    public var valueRange: NSRange

    public init(key: String, value: String, keyRange: NSRange, valueRange: NSRange) {
        self.key = key
        self.value = value
        self.keyRange = keyRange
        self.valueRange = valueRange
    }
}

public struct FrontMatter: Sendable {
    public var fields: [FrontMatterField]
    /// Whole block including the `---` fences.
    public var range: NSRange
    /// YAML body between the fences.
    public var bodyRange: NSRange

    public init(fields: [FrontMatterField], range: NSRange, bodyRange: NSRange) {
        self.fields = fields
        self.range = range
        self.bodyRange = bodyRange
    }

    public subscript(_ key: String) -> String? {
        fields.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
}

public enum ListMarkerStyle: String, Sendable {
    case dash = "-", asterisk = "*", plus = "+"
    case period = ".", paren = ")"
}

public indirect enum BlockContent: Sendable {
    case document
    case heading(level: Int)
    case paragraph
    case blockQuote
    case callout(kind: CalloutKind, title: String?)
    case list(ordered: Bool, start: Int, tight: Bool, marker: ListMarkerStyle)
    case listItem(ordinal: Int?, checkbox: Checkbox?)
    /// `code` is the fence body; `language` the info string's first word.
    case codeBlock(language: String?, isFenced: Bool, contentRange: NSRange)
    case mermaid(sourceRange: NSRange)
    case mathBlock(latexRange: NSRange)
    case table(TableData)
    case thematicBreak
    case htmlBlock
    case frontMatter(FrontMatter)
    case footnoteDefinition(identifier: String)

    public var isLeafText: Bool {
        switch self {
        case .paragraph, .heading: return true
        default: return false
        }
    }

    /// Blocks a structural-zoom level 4 keeps as "concrete artifacts" (§5.2).
    public var isConcreteArtifact: Bool {
        switch self {
        case .codeBlock, .table, .mermaid, .mathBlock: return true
        default: return false
        }
    }
}

/// A block-level node.  Reference type on purpose: the diff walks it, the
/// decorator caches against its identity, and copying subtrees for every edit
/// of a 5k-line document would blow the keystroke budget (§12).
public final class MDBlock: @unchecked Sendable {
    public var content: BlockContent
    /// Full source range, markers included.
    public var range: NSRange
    /// The renderable content, markers excluded.
    public var contentRange: NSRange
    /// Leading block marker — `"## "`, `"> "`, `"- [ ] "`.  Rendered in the
    /// gutter rather than inline (§6.1a), never at the start of the text.
    public var markerRange: NSRange?
    /// Trailing marker, e.g. the closing fence of a code block.
    public var trailingMarkerRange: NSRange?
    public var children: [MDBlock]
    /// Populated only for leaf text blocks.
    public var inlines: [InlineSpan]
    /// Nesting depth from the document root.
    public var depth: Int
    /// Depth of blockquote nesting containing this block.
    public var quoteDepth: Int
    /// Subtree hash used by `ASTDiff` to find the dirty set (§3.5).
    public var subtreeHash: UInt64
    /// Stable identity across reparses where possible, so fold/collapse state
    /// survives an agent rewriting an unrelated part of the file.
    public var identity: BlockIdentity

    public init(
        content: BlockContent,
        range: NSRange,
        contentRange: NSRange,
        markerRange: NSRange? = nil,
        trailingMarkerRange: NSRange? = nil,
        children: [MDBlock] = [],
        inlines: [InlineSpan] = [],
        depth: Int = 0,
        quoteDepth: Int = 0,
        subtreeHash: UInt64 = 0,
        identity: BlockIdentity = .init(kind: 0, ordinal: 0)
    ) {
        self.content = content
        self.range = range
        self.contentRange = contentRange
        self.markerRange = markerRange
        self.trailingMarkerRange = trailingMarkerRange
        self.children = children
        self.inlines = inlines
        self.depth = depth
        self.quoteDepth = quoteDepth
        self.subtreeHash = subtreeHash
        self.identity = identity
    }
}

public struct BlockIdentity: Hashable, Sendable {
    /// Discriminator for the block's kind, so a heading never matches a table.
    public var kind: Int
    /// Index among same-kind siblings.
    public var ordinal: Int

    public init(kind: Int, ordinal: Int) {
        self.kind = kind
        self.ordinal = ordinal
    }
}

extension MDBlock {
    /// Depth-first walk, self first.
    public func walk(_ visit: (MDBlock) -> Void) {
        visit(self)
        for child in children { child.walk(visit) }
    }

    /// Depth-first walk that can prune subtrees by returning `false`.
    public func walkPruning(_ visit: (MDBlock) -> Bool) {
        guard visit(self) else { return }
        for child in children { child.walkPruning(visit) }
    }

    public var headingLevel: Int? {
        if case .heading(let level) = content { return level }
        return nil
    }

    /// Deepest block whose range contains `offset`.
    public func block(at offset: Int) -> MDBlock? {
        guard range.touches(offset: offset) else { return nil }
        for child in children {
            if let hit = child.block(at: offset) { return hit }
        }
        return self
    }

    public func flattened() -> [MDBlock] {
        var out: [MDBlock] = []
        walk { out.append($0) }
        return out
    }
}

// MARK: - Inlines

public struct PathToken: Hashable, Sendable {
    public var rawPath: String
    public var line: Int?
    public var column: Int?

    public init(rawPath: String, line: Int? = nil, column: Int? = nil) {
        self.rawPath = rawPath
        self.line = line
        self.column = column
    }
}

public indirect enum InlineKind: Sendable {
    case text
    case emphasis
    case strong
    case strikethrough
    case inlineCode
    case link(destination: String, title: String?)
    case autolink(destination: String)
    case wikilink(target: String, label: String?)
    case image(source: String, alt: String)
    case inlineMath(latexRange: NSRange)
    case pathToken(PathToken)
    case footnoteReference(identifier: String)
    case softBreak
    case lineBreak
    case inlineHTML

    /// Whether the caret entering this span should reveal its markers (§6.1b).
    public var revealsMarkers: Bool {
        switch self {
        case .text, .softBreak, .lineBreak, .inlineHTML, .pathToken: return false
        default: return true
        }
    }
}

public struct InlineSpan: Sendable {
    public var kind: InlineKind
    /// Whole span, markers included.
    public var range: NSRange
    /// Inner content, markers excluded.
    public var contentRange: NSRange
    public var leadingMarkerRange: NSRange?
    public var trailingMarkerRange: NSRange?
    public var children: [InlineSpan]

    public init(
        kind: InlineKind,
        range: NSRange,
        contentRange: NSRange,
        leadingMarkerRange: NSRange? = nil,
        trailingMarkerRange: NSRange? = nil,
        children: [InlineSpan] = []
    ) {
        self.kind = kind
        self.range = range
        self.contentRange = contentRange
        self.leadingMarkerRange = leadingMarkerRange
        self.trailingMarkerRange = trailingMarkerRange
        self.children = children
    }

    public var markerRanges: [NSRange] {
        [leadingMarkerRange, trailingMarkerRange].compactMap { $0 }
    }

    public func walk(_ visit: (InlineSpan) -> Void) {
        visit(self)
        for child in children { child.walk(visit) }
    }

    /// Innermost span touching `offset`, used to decide what to reveal.
    public func span(touching offset: Int) -> InlineSpan? {
        guard range.touches(offset: offset) else { return nil }
        for child in children {
            if let hit = child.span(touching: offset) { return hit }
        }
        return self
    }
}

// MARK: - Document

public enum TextEncodingKind: String, Sendable {
    case utf8, utf16LE, utf16BE, utf32LE, utf32BE, latin1

    public var stringEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .utf32LE: return .utf32LittleEndian
        case .utf32BE: return .utf32BigEndian
        case .latin1: return .isoLatin1
        }
    }

    /// Approximate width of one code unit in bytes, used to repair a file that
    /// was truncated mid-code-unit (a torn UTF-16 surrogate pair or a UTF-32
    /// word sliced at a non-word boundary).
    var codeUnitWidth: Int {
        switch self {
        case .utf16LE, .utf16BE: return 2
        case .utf32LE, .utf32BE: return 4
        default: return 1
        }
    }
}

/// Byte-level facts about the file that must survive a round-trip untouched
/// (§3.1).  The app never normalises these; it records them and writes them
/// back exactly as found.
public struct ByteFidelity: Hashable, Sendable {
    public var encoding: TextEncodingKind
    public var hasBOM: Bool
    public var lineEnding: LineEnding
    public var hasTrailingNewline: Bool

    public init(encoding: TextEncodingKind, hasBOM: Bool, lineEnding: LineEnding, hasTrailingNewline: Bool) {
        self.encoding = encoding
        self.hasBOM = hasBOM
        self.lineEnding = lineEnding
        self.hasTrailingNewline = hasTrailingNewline
    }

    public static let `default` = ByteFidelity(
        encoding: .utf8, hasBOM: false, lineEnding: .lf, hasTrailingNewline: true
    )
}

public enum LineEnding: String, Sendable {
    case lf = "\n", crlf = "\r\n", cr = "\r"
}

/// A parsed document: the text, the tree over it, and the extension-pass
/// results.  Immutable — every edit produces a new one, and `ASTDiff` compares
/// the two to find what actually has to be re-decorated.
public final class ParsedDocument: @unchecked Sendable {
    public let text: String
    /// UTF-16 length, cached — `(text as NSString).length` is not free.
    public let length: Int
    public let root: MDBlock
    public let frontMatter: FrontMatter?
    public let headings: [HeadingNode]
    public let tasks: [TaskItem]
    public let pathTokens: [ResolvableToken]
    public let footnotes: [String: MDBlock]
    public let linkReferences: [String: LinkReference]
    /// Line start offsets, for `line:column` lookups.
    public let lineStarts: [Int]

    public init(
        text: String,
        length: Int,
        root: MDBlock,
        frontMatter: FrontMatter?,
        headings: [HeadingNode],
        tasks: [TaskItem],
        pathTokens: [ResolvableToken],
        footnotes: [String: MDBlock],
        linkReferences: [String: LinkReference],
        lineStarts: [Int]
    ) {
        self.text = text
        self.length = length
        self.root = root
        self.frontMatter = frontMatter
        self.headings = headings
        self.tasks = tasks
        self.pathTokens = pathTokens
        self.footnotes = footnotes
        self.linkReferences = linkReferences
        self.lineStarts = lineStarts
    }

    public static let empty = ParsedDocument(
        text: "", length: 0,
        root: MDBlock(content: .document, range: NSRange(location: 0, length: 0), contentRange: NSRange(location: 0, length: 0)),
        frontMatter: nil, headings: [], tasks: [], pathTokens: [], footnotes: [:], linkReferences: [:], lineStarts: [0]
    )

    /// 1-based line number containing `offset`.
    public func line(at offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lineStarts[mid] <= offset { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best + 1
    }

    /// Range of the 1-based line `line`, newline excluded.
    public func range(ofLine line: Int) -> NSRange {
        let idx = line - 1
        guard idx >= 0 && idx < lineStarts.count else { return NSRange(location: 0, length: 0) }
        let start = lineStarts[idx]
        let end = idx + 1 < lineStarts.count ? lineStarts[idx + 1] : length
        let ns = text as NSString
        var e = end
        while e > start, e - 1 < ns.length {
            let ch = ns.character(at: e - 1)
            if ch == 0x0A || ch == 0x0D { e -= 1 } else { break }
        }
        return NSRange(location: start, length: max(0, e - start))
    }

    public func substring(_ range: NSRange) -> String {
        guard range.location >= 0, range.upperBound <= length else { return "" }
        return (text as NSString).substring(with: range)
    }
}

public struct LinkReference: Sendable {
    public var identifier: String
    public var destination: String
    public var title: String?
    public var range: NSRange

    public init(identifier: String, destination: String, title: String?, range: NSRange) {
        self.identifier = identifier
        self.destination = destination
        self.title = title
        self.range = range
    }
}

// MARK: - Derived structures

public struct HeadingNode: Sendable {
    public var level: Int
    public var title: String
    /// Range of the heading line itself.
    public var range: NSRange
    /// Range of the heading text without the `#` markers.
    public var contentRange: NSRange
    /// Heading plus every block beneath it until the next heading of the same
    /// or higher level — the unit that folds, moves, and copies (§9.2).
    public var sectionRange: NSRange
    /// Index into `ParsedDocument.headings` of the parent heading.
    public var parentIndex: Int?
    public var childIndices: [Int]
    /// GitHub-style anchor slug.
    public var slug: String
    /// Words in this section excluding subsections, for §9.6 read time.
    public var wordCount: Int

    public init(
        level: Int, title: String, range: NSRange, contentRange: NSRange, sectionRange: NSRange,
        parentIndex: Int? = nil, childIndices: [Int] = [], slug: String = "", wordCount: Int = 0
    ) {
        self.level = level
        self.title = title
        self.range = range
        self.contentRange = contentRange
        self.sectionRange = sectionRange
        self.parentIndex = parentIndex
        self.childIndices = childIndices
        self.slug = slug
        self.wordCount = wordCount
    }
}

public struct TaskItem: Sendable {
    public var isChecked: Bool
    /// Single character between the brackets.
    public var markRange: NSRange
    /// The task's text.
    public var contentRange: NSRange
    public var text: String
    /// Index into `headings` of the nearest preceding heading.
    public var headingIndex: Int?
    public var indentLevel: Int

    public init(
        isChecked: Bool, markRange: NSRange, contentRange: NSRange, text: String,
        headingIndex: Int?, indentLevel: Int
    ) {
        self.isChecked = isChecked
        self.markRange = markRange
        self.contentRange = contentRange
        self.text = text
        self.headingIndex = headingIndex
        self.indentLevel = indentLevel
    }
}

/// A path-like token found by the extension pass, before resolution (§8.4).
/// Resolution is the app's job — it needs a document directory and a git root,
/// neither of which belongs in a pure parser.
public struct ResolvableToken: Sendable {
    public var token: PathToken
    public var range: NSRange
    /// True when the token came from an inline code span, which is a much
    /// stronger signal that it is a path and lets us relax the shape rules.
    public var fromCodeSpan: Bool

    public init(token: PathToken, range: NSRange, fromCodeSpan: Bool) {
        self.token = token
        self.range = range
        self.fromCodeSpan = fromCodeSpan
    }
}
