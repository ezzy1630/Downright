import Foundation
import MarkdownCore

public struct WorkspaceSearchQuery: Sendable, Equatable {
    public var text: String
    public var isRegex: Bool
    public var caseSensitive: Bool
    public var wholeWord: Bool

    public init(text: String, isRegex: Bool = false, caseSensitive: Bool = false, wholeWord: Bool = false) {
        self.text = text
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
    }

    var pattern: String? {
        guard !text.isEmpty else { return nil }
        let escaped = isRegex ? text : NSRegularExpression.escapedPattern(for: text)
        return wholeWord ? "\\b\(escaped)\\b" : escaped
    }
}

public struct WorkspaceSearchResult: Sendable, Hashable, Identifiable {
    public var id: String { "\(fileID):\(range.location):\(range.length)" }
    public let fileID: String
    public let url: URL
    public let relativePath: String
    public let range: NSRange
    public let contextRange: NSRange
    public let contextText: String
    public let line: Int
    public let heading: String?

    public init(
        fileID: String,
        url: URL,
        relativePath: String,
        range: NSRange,
        contextRange: NSRange,
        contextText: String,
        line: Int,
        heading: String?
    ) {
        self.fileID = fileID
        self.url = url
        self.relativePath = relativePath
        self.range = range
        self.contextRange = contextRange
        self.contextText = contextText
        self.line = line
        self.heading = heading
    }
}

public struct WorkspaceSearchMention: Sendable, Hashable, Identifiable {
    public var id: String { "\(fileID):\(range.location):\(target)" }
    public let fileID: String
    public let range: NSRange
    public let target: String

    public init(fileID: String, range: NSRange, target: String) {
        self.fileID = fileID
        self.range = range
        self.target = target
    }
}

enum WorkspaceSearch {
    static func search(
        _ query: WorkspaceSearchQuery,
        in snapshot: WorkspaceIndexSnapshot,
        limitPerFile: Int = 100
    ) -> [WorkspaceSearchResult] {
        guard let pattern = query.pattern,
              let regex = try? NSRegularExpression(
                pattern: pattern,
                options: query.caseSensitive ? [] : [.caseInsensitive]
              ) else { return [] }
        return snapshot.entries.flatMap { entry in
            let full = NSRange(location: 0, length: (entry.text as NSString).length)
            return regex.matches(in: entry.text, options: [], range: full)
                .prefix(limitPerFile)
                .map { match in
                    let context = contextRange(for: match.range, in: entry)
                    let heading = entry.headings.last { $0.range.location <= match.range.location }?.title
                    return WorkspaceSearchResult(
                        fileID: entry.id, url: entry.url, relativePath: entry.relativePath,
                        range: match.range, contextRange: context,
                        contextText: (entry.text as NSString).substring(with: context),
                        line: line(at: match.range.location, in: entry.text), heading: heading
                    )
                }
        }
    }

    static func isValid(_ query: WorkspaceSearchQuery) -> Bool {
        guard let pattern = query.pattern else { return true }
        return (try? NSRegularExpression(pattern: pattern, options: query.caseSensitive ? [] : [.caseInsensitive])) != nil
    }

    static func unlinkedMentions(
        snapshot: WorkspaceIndexSnapshot,
        graph: WorkspaceLinkGraph?
    ) -> [String: [WorkspaceSearchMention]] {
        let linkedPairs = Set((graph?.outgoing ?? [:]).flatMap { source, links in
            links.compactMap { link in link.targetFile.map { "\(source)->\($0)" } }
        })
        var result: [String: [WorkspaceSearchMention]] = [:]
        for target in snapshot.entries {
            let stem = URL(fileURLWithPath: target.relativePath).deletingPathExtension().lastPathComponent
            guard stem.count > 1 else { continue }
            let query = WorkspaceSearchQuery(text: stem, wholeWord: true)
            for source in snapshot.entries
            where source.id != target.id && !linkedPairs.contains("\(source.id)->\(target.id)") {
                for hit in search(query, in: WorkspaceIndexSnapshot(
                    rootURL: snapshot.rootURL, revision: snapshot.revision, entries: [source]
                ), limitPerFile: 20) {
                    result[target.id, default: []].append(WorkspaceSearchMention(
                        fileID: source.id, range: hit.range, target: stem
                    ))
                }
            }
        }
        return result
    }

    private static func contextRange(for range: NSRange, in entry: WorkspaceIndexEntry) -> NSRange {
        let line = line(at: range.location, in: entry.text)
        return rangeOfLine(line, in: entry.text)
    }

    private static func line(at offset: Int, in text: String) -> Int {
        let ns = text as NSString
        guard !text.isEmpty else { return 1 }
        var line = 1
        var index = 0
        while index < min(offset, ns.length) {
            if ns.character(at: index) == 0x0A { line += 1 }
            index += 1
        }
        return line
    }

    private static func rangeOfLine(_ line: Int, in text: String) -> NSRange {
        let ns = text as NSString
        var current = 1
        var start = 0
        var index = 0
        while index < ns.length, current < line {
            if ns.character(at: index) == 0x0A { current += 1; start = index + 1 }
            index += 1
        }
        var end = start
        while end < ns.length, ns.character(at: end) != 0x0A { end += 1 }
        return NSRange(location: start, length: max(0, end - start))
    }
}

/// Async search coordinator.  A new query cancels the old one and only the
/// latest revision may call `onUpdate`.
@MainActor
final class WorkspaceSearchSession {
    var onUpdate: (([WorkspaceSearchResult]) -> Void)?
    private var task: Task<Void, Never>?
    private var revision = 0

    deinit { task?.cancel() }

    func start(query: WorkspaceSearchQuery, snapshot: WorkspaceIndexSnapshot) {
        revision += 1
        let currentRevision = revision
        task?.cancel()
        task = Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                WorkspaceSearch.search(query, in: snapshot)
            }.value
            guard !Task.isCancelled else { return }
            guard let self, self.revision == currentRevision else { return }
            self.onUpdate?(results)
        }
    }

    func cancel() {
        revision += 1
        task?.cancel()
        task = nil
    }
}
