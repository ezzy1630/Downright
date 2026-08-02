import Foundation

// Result and option types shared across modules.  Declared separately from the
// code that produces them so the render and app layers can compile against a
// stable surface.

// MARK: - Parsing

public struct ParseOptions: Sendable {
    public var detectFrontMatter: Bool
    public var detectMath: Bool
    public var detectCallouts: Bool
    public var detectWikilinks: Bool
    public var detectPathTokens: Bool
    public var detectMermaid: Bool
    /// Beyond this UTF-16 length the parser stops running the optional
    /// extension passes so very large files still open promptly (§15 Q4).
    public var extensionPassLimit: Int

    public init(
        detectFrontMatter: Bool = true,
        detectMath: Bool = true,
        detectCallouts: Bool = true,
        detectWikilinks: Bool = true,
        detectPathTokens: Bool = true,
        detectMermaid: Bool = true,
        extensionPassLimit: Int = 5_000_000
    ) {
        self.detectFrontMatter = detectFrontMatter
        self.detectMath = detectMath
        self.detectCallouts = detectCallouts
        self.detectWikilinks = detectWikilinks
        self.detectPathTokens = detectPathTokens
        self.detectMermaid = detectMermaid
        self.extensionPassLimit = extensionPassLimit
    }

    public static let `default` = ParseOptions()
    /// Everything off but the structure — used by the thumbnail generator.
    public static let structureOnly = ParseOptions(
        detectFrontMatter: true, detectMath: false, detectCallouts: true,
        detectWikilinks: false, detectPathTokens: false, detectMermaid: false
    )
}

// MARK: - AST diff (§3.5)

/// What changed between two parses.  The decorator restyles exactly these
/// ranges and nothing else; that is the whole reason full reparse is cheap
/// enough to do on every keystroke.
public struct DirtySet: Sendable {
    /// Source ranges (in the *new* document) needing re-decoration.
    public var ranges: [NSRange]
    /// Set when the structure changed so much that block-level diffing is not
    /// worth it — the caller should redecorate everything.
    public var isWholesale: Bool

    public init(ranges: [NSRange], isWholesale: Bool) {
        self.ranges = ranges
        self.isWholesale = isWholesale
    }

    public static let wholesale = DirtySet(ranges: [], isWholesale: true)
    public static let none = DirtySet(ranges: [], isWholesale: false)
    public var isEmpty: Bool { !isWholesale && ranges.isEmpty }
}

// MARK: - Text diff (§8.1)

public enum ChangeKind: String, Sendable {
    case inserted, deleted, modified
}

/// A change between two versions of a document, expressed in ranges of the new
/// text (and of the old text, for deletions).  Deliberately block-shaped rather
/// than line-shaped: the app highlights changed words inside rendered prose,
/// never `+`/`-` gutters.
public struct ChangeHunk: Sendable {
    public var kind: ChangeKind
    /// Range in the new text.  Zero-length for a pure deletion, positioned
    /// where the deleted text used to start.
    public var newRange: NSRange
    /// Range in the old text.  Zero-length for a pure insertion.
    public var oldRange: NSRange
    /// Word-level ranges within `newRange` that actually differ, for
    /// highlighting inside a modified paragraph.
    public var wordRanges: [NSRange]

    public init(kind: ChangeKind, newRange: NSRange, oldRange: NSRange, wordRanges: [NSRange] = []) {
        self.kind = kind
        self.newRange = newRange
        self.oldRange = oldRange
        self.wordRanges = wordRanges
    }
}

// MARK: - Tidy (§9.1)

public enum TidyRule: String, Sendable, CaseIterable {
    case headingLevels        // H2 → H4 jumps collapsed to H2 → H3
    case tablePipes           // realign
    case blankLines           // collapse 3+ blank lines to 1
    case codeFenceLanguages   // add a guessed language hint
    case orderedListNumbers   // renumber 1. 2. 3.
    case listMarkers          // normalise to a single bullet char
    case trailingWhitespace   // strip, except a deliberate two-space break

    public var title: String {
        switch self {
        case .headingLevels: return "Fix skipped heading levels"
        case .tablePipes: return "Align table pipes"
        case .blankLines: return "Collapse blank line runs"
        case .codeFenceLanguages: return "Add code fence languages"
        case .orderedListNumbers: return "Renumber ordered lists"
        case .listMarkers: return "Normalise list markers"
        case .trailingWhitespace: return "Trim trailing whitespace"
        }
    }
}

/// One accept/reject-able edit.  Everything the app mutates a document with
/// goes through this type, which is what makes "show a rendered diff before
/// applying" (§9.1) uniform rather than per-command.
public struct TextEdit: Sendable, Identifiable {
    public var id: UUID
    public var range: NSRange
    public var replacement: String
    /// Human-readable description for the diff sheet.
    public var summary: String
    public var rule: TidyRule?

    public init(id: UUID = UUID(), range: NSRange, replacement: String, summary: String, rule: TidyRule? = nil) {
        self.id = id
        self.range = range
        self.replacement = replacement
        self.summary = summary
        self.rule = rule
    }
}

extension Array where Element == TextEdit {
    /// Applies edits to `text`, back to front so earlier offsets stay valid.
    /// Overlapping edits are resolved by dropping the later one.
    public func applied(to text: String) -> String {
        let ns = NSMutableString(string: text)
        var lastStart = Int.max
        for edit in sorted(by: { $0.range.location > $1.range.location }) {
            guard edit.range.upperBound <= lastStart else { continue }
            guard edit.range.location >= 0, edit.range.upperBound <= ns.length else { continue }
            ns.replaceCharacters(in: edit.range, with: edit.replacement)
            lastStart = edit.range.location
        }
        return ns as String
    }
}

// MARK: - Restructuring (§9.2)

public enum ListConversion: String, Sendable, CaseIterable {
    case paragraph, bulletList, numberedList, taskList, blockquote

    public var title: String {
        switch self {
        case .paragraph: return "Paragraph"
        case .bulletList: return "Bullet List"
        case .numberedList: return "Numbered List"
        case .taskList: return "Task List"
        case .blockquote: return "Blockquote"
        }
    }
}

public enum ListSortOrder: String, Sendable {
    case alphabetical, reverseAlphabetical, uncheckedFirst, checkedFirst
}

// MARK: - Reading metrics (§9.6)

public struct ReadingMetrics: Sendable {
    public var words: Int
    public var characters: Int
    public var sentences: Int
    /// Minutes at 238 wpm — the median silent-reading rate for prose.
    public var readMinutes: Double

    public init(words: Int, characters: Int, sentences: Int, readMinutes: Double) {
        self.words = words
        self.characters = characters
        self.sentences = sentences
        self.readMinutes = readMinutes
    }

    public static let zero = ReadingMetrics(words: 0, characters: 0, sentences: 0, readMinutes: 0)
}

// MARK: - Structural zoom (§5.2)

public enum ZoomLevel: Int, Codable, Sendable, CaseIterable, Comparable {
    case h1 = 1, h2 = 2, headings = 3, skeleton = 4, everything = 5

    public static func < (a: ZoomLevel, b: ZoomLevel) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .h1: return "Top level"
        case .h2: return "Two levels"
        case .headings: return "All headings"
        case .skeleton: return "Skeleton"
        case .everything: return "Everything"
        }
    }

    /// Deepest heading level still shown.
    public var maxHeadingLevel: Int {
        switch self {
        case .h1: return 1
        case .h2: return 2
        default: return 6
        }
    }
}

/// Which source ranges survive at a given zoom level.  Computed in Core so the
/// Quick Look extension gets identical behaviour without importing any UI.
public struct ZoomPlan: Sendable {
    /// Ranges to keep visible, in ascending order and non-overlapping.
    public var visibleRanges: [NSRange]
    /// Ranges elided, each mapped to the heading it belongs to for the
    /// "N paragraphs hidden" affordance.
    public var elidedRanges: [NSRange]

    public init(visibleRanges: [NSRange], elidedRanges: [NSRange]) {
        self.visibleRanges = visibleRanges
        self.elidedRanges = elidedRanges
    }

    public static let all = ZoomPlan(visibleRanges: [], elidedRanges: [])
    public var isIdentity: Bool { elidedRanges.isEmpty }
}
