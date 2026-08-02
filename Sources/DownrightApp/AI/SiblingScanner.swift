import Foundation
import MarkdownCore

/// Sibling files (§8.7).
///
/// Agents don't write one file, they write six into the same folder.  So on
/// open we scan the containing directory — plus one level into `docs/`,
/// `plans/`, `.claude/` and friends — and keep the result to hand.
///
/// Explicitly **not** an index and **not** a vault (§2).  No database, no
/// crawl, no "open folder" ceremony: one shallow directory listing, sorted by
/// modification time, recomputed when the directory changes.
final class SiblingScanner {
    struct Sibling: Identifiable, Equatable {
        var id: String { url.path }
        var url: URL
        var displayName: String
        var modified: Date
        var byteCount: Int
        /// Set when the file changed since the user last looked at it — the
        /// dot in the sidebar.
        var hasUnseenChanges: Bool
        /// Relative label for files found one level down, e.g. "docs".
        var group: String?
        var isCurrent: Bool
    }

    private(set) var siblings: [Sibling] = []
    var onChange: (() -> Void)?

    private let documentURL: URL
    private let extraDirectories: [String]
    private var watcher: FileWatcher?
    private let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mdx", "mdc", "qmd", "rmd",
    ]
    /// A directory full of agent output can be large; a hard cap keeps the
    /// sidebar a glance rather than a file browser.
    private let limit = 200
    private struct ContentFingerprint: Hashable {
        let path: String
        let modified: Date
        let byteCount: Int
    }
    private var contentHashCache: [ContentFingerprint: String] = [:]
    private var contentHashOrder: [ContentFingerprint] = []
    private let contentHashCacheLimit = 256

    init(documentURL: URL, extraDirectories: [String]) {
        self.documentURL = documentURL.resolvingSymlinksInPath()
        self.extraDirectories = extraDirectories
        scan()
        startWatching()
    }

    deinit { watcher?.stop() }

    // MARK: - Scanning

    func scan() {
        let directory = documentURL.deletingLastPathComponent()
        var found: [Sibling] = []
        found.append(contentsOf: markdownFiles(in: directory, group: nil))

        for name in extraDirectories {
            let sub = directory.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sub.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            found.append(contentsOf: markdownFiles(in: sub, group: name))
        }

        // Newest first: the file the agent just wrote is the one you want.
        found.sort { a, b in
            if a.isCurrent != b.isCurrent { return a.isCurrent }
            return a.modified > b.modified
        }
        siblings = Array(found.prefix(limit))
        onChange?()
    }

    private func markdownFiles(in directory: URL, group: String?) -> [Sibling] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsSubdirectoryDescendants]
        ) else { return [] }

        return entries.compactMap { url -> Sibling? in
            guard markdownExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }

            let modified = values.contentModificationDate ?? .distantPast
            let state = DocumentStateStore.shared.state(for: url)
            // "Changed since you last looked" is a comparison against the hash
            // recorded when the document was last closed (§8.2), not against a
            // timestamp — an agent that rewrites a file with identical content
            // should not light up the sidebar.
            let unseen: Bool
            if state.lastSeenHash.isEmpty {
                unseen = false
            } else if let hash = contentHash(for: url, modified: modified, byteCount: values.fileSize ?? 0) {
                unseen = hash != state.lastSeenHash
            } else {
                unseen = false
            }

            return Sibling(
                url: url,
                displayName: url.deletingPathExtension().lastPathComponent,
                modified: modified,
                byteCount: values.fileSize ?? 0,
                hasUnseenChanges: unseen && url.resolvingSymlinksInPath() != documentURL,
                group: group,
                isCurrent: url.resolvingSymlinksInPath() == documentURL
            )
        }
    }

    private func contentHash(for url: URL, modified: Date, byteCount: Int) -> String? {
        let key = ContentFingerprint(
            path: url.standardizedFileURL.path,
            modified: modified,
            byteCount: byteCount
        )
        if let cached = contentHashCache[key] {
            touchContentHash(key)
            return cached
        }

        guard let data = try? Data(contentsOf: url),
              String(data: data, encoding: .utf8) != nil else { return nil }
        let hash = SnapshotStore.hash(data)
        contentHashCache[key] = hash
        touchContentHash(key)
        while contentHashOrder.count > contentHashCacheLimit {
            contentHashCache.removeValue(forKey: contentHashOrder.removeFirst())
        }
        return hash
    }

    private func touchContentHash(_ key: ContentFingerprint) {
        contentHashOrder.removeAll { $0 == key }
        contentHashOrder.append(key)
    }

    // MARK: - Watching

    /// Watching the *directory* rather than each file means a newly written
    /// sibling appears without a rescan timer — which is the case that matters,
    /// since the sixth file usually arrives after you have opened the first.
    private func startWatching() {
        watcher = FileWatcher(url: documentURL.deletingLastPathComponent(), watchesDirectory: true) { [weak self] _ in
            self?.scan()
        }
    }

    // MARK: - Cycling (§8.7, ⌥⌘← / ⌥⌘→)

    func neighbour(after url: URL, forward: Bool) -> URL? {
        guard siblings.count > 1 else { return nil }
        guard let index = siblings.firstIndex(where: { $0.url.path == url.path }) else {
            return siblings.first?.url
        }
        let next = forward
            ? (index + 1) % siblings.count
            : (index - 1 + siblings.count) % siblings.count
        return siblings[next].url
    }

    /// Groups for the sidebar's section headers, preserving scan order.
    func grouped() -> [(group: String?, items: [Sibling])] {
        var order: [String?] = []
        var buckets: [String?: [Sibling]] = [:]
        for sibling in siblings {
            if buckets[sibling.group] == nil { order.append(sibling.group) }
            buckets[sibling.group, default: []].append(sibling)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}
