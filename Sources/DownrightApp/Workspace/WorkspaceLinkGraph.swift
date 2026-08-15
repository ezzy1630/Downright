import Foundation

public struct WorkspaceLinkTarget: Sendable, Hashable {
    public let sourceFile: String
    public let sourceRange: NSRange
    public let destination: String
    public let targetFile: String?

    public init(sourceFile: String, sourceRange: NSRange, destination: String, targetFile: String?) {
        self.sourceFile = sourceFile
        self.sourceRange = sourceRange
        self.destination = destination
        self.targetFile = targetFile
    }
}

public struct WorkspaceBacklink: Sendable, Hashable, Identifiable {
    public var id: String { "\(sourceFile):\(sourceRange.location):\(targetFile)" }
    public let sourceFile: String
    public let sourceRange: NSRange
    public let targetFile: String
    public let destination: String

    public init(sourceFile: String, sourceRange: NSRange, targetFile: String, destination: String) {
        self.sourceFile = sourceFile
        self.sourceRange = sourceRange
        self.targetFile = targetFile
        self.destination = destination
    }
}

public struct WorkspaceLinkGraph: Sendable, Equatable {
    public let outgoing: [String: [WorkspaceLinkTarget]]
    public let backlinks: [String: [WorkspaceBacklink]]
    public let unresolved: [WorkspaceLinkTarget]
    public let unlinkedMentions: [String: [WorkspaceSearchMention]]

    public init(
        outgoing: [String: [WorkspaceLinkTarget]],
        backlinks: [String: [WorkspaceBacklink]],
        unresolved: [WorkspaceLinkTarget],
        unlinkedMentions: [String: [WorkspaceSearchMention]] = [:]
    ) {
        self.outgoing = outgoing
        self.backlinks = backlinks
        self.unresolved = unresolved
        self.unlinkedMentions = unlinkedMentions
    }

    public static let empty = WorkspaceLinkGraph(outgoing: [:], backlinks: [:], unresolved: [])

    public func linksTo(fileID: String) -> [WorkspaceBacklink] { backlinks[fileID] ?? [] }
}

enum WorkspaceLinkGraphBuilder {
    static func build(snapshot: WorkspaceIndexSnapshot, includeUnlinkedMentions: Bool = false) -> WorkspaceLinkGraph {
        // `normalize` folds distinct files together (`a\b.md` vs `a/b.md`, and
        // a hidden `.x.md` vs `x.md`), so a plain uniqueKeysWithValues would
        // trap on the first duplicate.  Prefer the entry whose relative path is
        // already normalized (no backslash folding or `./` trimming); among
        // ties the sorted scan order decides, so the winner is deterministic.
        var byPath: [String: WorkspaceIndexEntry] = [:]
        for entry in snapshot.entries {
            let key = normalize(entry.relativePath)
            if let existing = byPath[key] {
                if existing.relativePath != key, entry.relativePath == key {
                    byPath[key] = entry
                }
                continue
            }
            byPath[key] = entry
        }
        let byStem = Dictionary(grouping: snapshot.entries) { normalize(URL(fileURLWithPath: $0.relativePath).deletingPathExtension().path) }
        var outgoing: [String: [WorkspaceLinkTarget]] = [:]
        var backlinks: [String: [WorkspaceBacklink]] = [:]
        var unresolved: [WorkspaceLinkTarget] = []

        for entry in snapshot.entries {
            for link in entry.links {
                let target = resolve(link.destination, source: entry, byPath: byPath, byStem: byStem)
                let item = WorkspaceLinkTarget(
                    sourceFile: entry.id, sourceRange: link.range,
                    destination: link.destination, targetFile: target?.id
                )
                outgoing[entry.id, default: []].append(item)
                if let target {
                    backlinks[target.id, default: []].append(WorkspaceBacklink(
                        sourceFile: entry.id, sourceRange: link.range,
                        targetFile: target.id, destination: link.destination
                    ))
                } else if isLocal(link.destination) {
                    unresolved.append(item)
                }
            }
        }

        let mentions = includeUnlinkedMentions ? WorkspaceSearch.unlinkedMentions(snapshot: snapshot, graph: nil) : [:]
        return WorkspaceLinkGraph(outgoing: outgoing, backlinks: backlinks, unresolved: unresolved, unlinkedMentions: mentions)
    }

    private static func resolve(
        _ destination: String,
        source: WorkspaceIndexEntry,
        byPath: [String: WorkspaceIndexEntry],
        byStem: [String: [WorkspaceIndexEntry]]
    ) -> WorkspaceIndexEntry? {
        guard isLocal(destination) else { return nil }
        let raw = destination
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let withoutFragment = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        let withoutQuery = withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? withoutFragment
        let decoded = withoutQuery.removingPercentEncoding ?? withoutQuery
        let path: String
        if destination.isEmpty { return nil }
        if destination.hasPrefix("/") {
            path = normalize(String(decoded.dropFirst()))
        } else if raw.hasPrefix("[[") {
            path = normalize(decoded)
        } else {
            let sourceDirectory = (source.relativePath as NSString).deletingLastPathComponent
            let combined = sourceDirectory == "." ? decoded : sourceDirectory + "/" + decoded
            path = normalize(combined)
        }
        if let exact = byPath[path] { return exact }
        let withMarkdown = path.lowercased().hasSuffix(".md") ? path : path + ".md"
        if let exact = byPath[withMarkdown] { return exact }
        return byStem[path]?.count == 1 ? byStem[path]?.first : byStem[withMarkdown]?.count == 1 ? byStem[withMarkdown]?.first : nil
    }

    private static func isLocal(_ destination: String) -> Bool {
        let value = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        if value.hasPrefix("#") { return false }
        if value.contains("://") { return false }
        let externalSchemes = ["mailto:", "javascript:", "data:", "file:"]
        return !externalSchemes.contains { value.lowercased().hasPrefix($0) }
    }

    private static func normalize(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "./"))
    }
}
