import Foundation
import MarkdownCore

/// Find and replace (§9.4).
///
/// Search runs over the **source** text, always.  That is what makes a match
/// inside a hidden marker, a collapsed section, or an elided structural-zoom
/// range findable at all — the view's job is then to reveal whatever contains
/// the hit, which it can only do if the engine reports hits it currently isn't
/// showing.  A search over the rendered text would silently lose them.
struct FindQuery: Equatable {
    var text: String = ""
    var isRegex: Bool = false
    var caseSensitive: Bool = false
    var wholeWord: Bool = false
    /// Restricts the search, for "in selection" mode.
    var scope: NSRange?

    var isEmpty: Bool { text.isEmpty }

    fileprivate var pattern: String? {
        guard !text.isEmpty else { return nil }
        let escaped = isRegex ? text : NSRegularExpression.escapedPattern(for: text)
        return wholeWord ? "\\b\(escaped)\\b" : escaped
    }

    fileprivate var options: NSRegularExpression.Options {
        caseSensitive ? [] : [.caseInsensitive]
    }
}

enum FindEngine {
    /// All matches, ascending.  Returns empty rather than throwing on a
    /// half-typed regex — the user is still typing and an error dialog per
    /// keystroke would be intolerable.
    static func matches(in text: String, query: FindQuery) -> [NSRange] {
        guard let pattern = query.pattern,
              let regex = try? NSRegularExpression(pattern: pattern, options: query.options)
        else { return [] }

        let full = NSRange(location: 0, length: (text as NSString).length)
        let scope = query.scope.map { NSIntersectionRange($0, full) } ?? full
        guard scope.length > 0 else { return [] }

        return regex.matches(in: text, options: [], range: scope)
            .map(\.range)
            .filter { $0.length > 0 }
    }

    /// Whether a partially typed regex is currently valid, for the field's
    /// error affordance.
    static func isValid(_ query: FindQuery) -> Bool {
        guard let pattern = query.pattern else { return true }
        return (try? NSRegularExpression(pattern: pattern, options: query.options)) != nil
    }

    /// Expands `$1`-style references when the query is a regex; otherwise the
    /// template is literal, which is what a non-regex user expects of a `$`.
    static func replacement(for match: NSRange, in text: String, query: FindQuery, template: String) -> String {
        guard query.isRegex, let pattern = query.pattern,
              let regex = try? NSRegularExpression(pattern: pattern, options: query.options),
              let result = regex.firstMatch(in: text, options: [.anchored], range: match)
        else { return template }
        return regex.replacementString(for: result, in: text, offset: 0, template: template)
    }

    static func replaceAllEdits(in text: String, query: FindQuery, template: String) -> [TextEdit] {
        matches(in: text, query: query).map { range in
            TextEdit(
                range: range,
                replacement: replacement(for: range, in: text, query: query, template: template),
                summary: "Replace"
            )
        }
    }
}

/// Tracks the current match across edits so `⌘G` means "the next one after
/// where I am", not "the next one after the last one I happened to visit".
final class FindSession {
    private(set) var query = FindQuery()
    private(set) var matches: [NSRange] = []
    private(set) var currentIndex: Int?

    var isEmpty: Bool { matches.isEmpty }
    var count: Int { matches.count }

    var statusText: String {
        guard !query.isEmpty else { return "" }
        guard !matches.isEmpty else { return "No matches" }
        guard let currentIndex else { return "\(matches.count) matches" }
        return "\(currentIndex + 1) of \(matches.count)"
    }

    var currentMatch: NSRange? {
        guard let currentIndex, currentIndex < matches.count else { return nil }
        return matches[currentIndex]
    }

    func update(query: FindQuery, in text: String, caret: Int) {
        self.query = query
        matches = FindEngine.matches(in: text, query: query)
        currentIndex = matches.firstIndex { $0.location >= caret } ?? (matches.isEmpty ? nil : 0)
    }

    @discardableResult
    func advance(forward: Bool) -> NSRange? {
        guard !matches.isEmpty else { return nil }
        let index = currentIndex ?? (forward ? -1 : 0)
        let next = forward
            ? (index + 1) % matches.count
            : (index - 1 + matches.count) % matches.count
        currentIndex = next
        return matches[next]
    }

    func clear() {
        query = FindQuery()
        matches = []
        currentIndex = nil
    }
}

// MARK: - Cross-file search (§9.4, ⌘⇧F)

/// Searches sibling files and returns enough context to render each hit.
/// Still no index and no vault (§2): it reads the same shallow file list the
/// sidebar already has, on demand.
enum SiblingSearch {
    struct Hit: Identifiable {
        var id: String { "\(url.path):\(range.location)" }
        var url: URL
        var displayName: String
        /// Range within that file's text.
        var range: NSRange
        /// The containing paragraph or heading line, for rendered context.
        var contextRange: NSRange
        var contextText: String
        var headingTitle: String?
        var lineNumber: Int
    }

    static func search(_ query: FindQuery, in urls: [URL], limitPerFile: Int = 20) -> [Hit] {
        var hits: [Hit] = []
        for url in urls {
            guard let (text, _) = try? DocumentIO.read(contentsOf: url) else { continue }
            let ranges = FindEngine.matches(in: text, query: query)
            guard !ranges.isEmpty else { continue }

            let document = MarkdownParser.parse(text, options: .structureOnly)
            for range in ranges.prefix(limitPerFile) {
                let context = contextRange(for: range, in: document)
                hits.append(Hit(
                    url: url,
                    displayName: url.deletingPathExtension().lastPathComponent,
                    range: range,
                    contextRange: context,
                    contextText: document.substring(context),
                    headingTitle: enclosingHeading(for: range, in: document)?.title,
                    lineNumber: document.line(at: range.location)
                ))
            }
        }
        return hits
    }

    private static func contextRange(for range: NSRange, in document: ParsedDocument) -> NSRange {
        guard let block = document.root.block(at: range.location) else {
            return document.range(ofLine: document.line(at: range.location))
        }
        // A whole code block or table as context is too much; a line is enough.
        switch block.content {
        case .paragraph, .heading:
            return block.range
        default:
            return document.range(ofLine: document.line(at: range.location))
        }
    }

    private static func enclosingHeading(for range: NSRange, in document: ParsedDocument) -> HeadingNode? {
        document.headings.last { $0.range.location <= range.location }
    }
}
