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
    private let scanQueue = DispatchQueue(label: "com.ezzyrappeport.downright.sibling-scan", qos: .utility)
    private var scanGeneration: UInt64 = 0

    /// Files above this size are not content-hashed for the "changed since you
    /// last looked" dot: reading and SHA-256-ing them on open would stall the
    /// first frame for a dot that carries no real signal.
    private let changeHashMaxBytes = 2 * 1024 * 1024

    init(documentURL: URL, extraDirectories: [String]) {
        self.documentURL = documentURL.resolvingSymlinksInPath()
        self.extraDirectories = extraDirectories
        // First pass: pure directory listing, no content hashing — instant for
        // the first paint.  The second pass computes unseen-change dots off the
        // scan queue so a folder of agent output never blocks opening the file.
        scan(synchronously: true, computeChanges: false)
        scan(synchronously: false, computeChanges: true)
        startWatching()
    }

    deinit { watcher?.stop() }

    // MARK: - Scanning

    /// Directory listing; `computeChanges: true` additionally reads and hashes
    /// each sibling for the "changed since you last looked" dot.  Watcher-driven
    /// rescans run off the main thread; the initial open path stays synchronous
    /// so the sidebar has rows before the first paint, but *listing only*.
    func scan(synchronously: Bool = false, computeChanges: Bool = true) {
        if synchronously {
            scanGeneration &+= 1
            var cache = contentHashCache
            var order = contentHashOrder
            let found = buildSiblings(
                documentURL: documentURL,
                extraDirectories: extraDirectories,
                markdownExtensions: markdownExtensions,
                limit: limit,
                computeChanges: computeChanges,
                cache: &cache,
                order: &order
            )
            contentHashCache = cache
            contentHashOrder = order
            siblings = found
            onChange?()
            return
        }

        scanGeneration &+= 1
        let generation = scanGeneration
        let documentURL = documentURL
        let extraDirectories = extraDirectories
        let limit = limit
        let markdownExtensions = markdownExtensions
        var cache = contentHashCache
        var order = contentHashOrder
        scanQueue.async { [weak self] in
            guard let self else { return }
            let found = self.buildSiblings(
                documentURL: documentURL,
                extraDirectories: extraDirectories,
                markdownExtensions: markdownExtensions,
                limit: limit,
                computeChanges: computeChanges,
                cache: &cache,
                order: &order
            )
            DispatchQueue.main.async {
                guard self.scanGeneration == generation else { return }
                self.contentHashCache = cache
                self.contentHashOrder = order
                self.siblings = found
                self.onChange?()
            }
        }
    }

    private func buildSiblings(
        documentURL: URL,
        extraDirectories: [String],
        markdownExtensions: Set<String>,
        limit: Int,
        computeChanges: Bool,
        cache: inout [ContentFingerprint: String],
        order: inout [ContentFingerprint]
    ) -> [Sibling] {
        let directory = documentURL.deletingLastPathComponent()
        var found: [Sibling] = []
        found.append(contentsOf: markdownFiles(
            in: directory, group: nil, documentURL: documentURL,
            markdownExtensions: markdownExtensions, computeChanges: computeChanges,
            cache: &cache, order: &order
        ))

        for name in extraDirectories {
            let sub = directory.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sub.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            found.append(contentsOf: markdownFiles(
                in: sub, group: name, documentURL: documentURL,
                markdownExtensions: markdownExtensions, computeChanges: computeChanges,
                cache: &cache, order: &order
            ))
        }

        found.sort { a, b in
            if a.isCurrent != b.isCurrent { return a.isCurrent }
            return a.modified > b.modified
        }
        return Array(found.prefix(limit))
    }

    private func markdownFiles(
        in directory: URL,
        group: String?,
        documentURL: URL,
        markdownExtensions: Set<String>,
        computeChanges: Bool,
        cache: inout [ContentFingerprint: String],
        order: inout [ContentFingerprint]
    ) -> [Sibling] {
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
            let size = values.fileSize ?? 0
            let unseen: Bool
            if state.lastSeenHash.isEmpty {
                unseen = false
            } else if !computeChanges || size > changeHashMaxBytes {
                unseen = false
            } else if let hash = contentHash(
                for: url, modified: modified, byteCount: size,
                cache: &cache, order: &order
            ) {
                unseen = hash != state.lastSeenHash
            } else {
                unseen = false
            }

            return Sibling(
                url: url,
                displayName: url.deletingPathExtension().lastPathComponent,
                modified: modified,
                byteCount: size,
                hasUnseenChanges: unseen && url.resolvingSymlinksInPath() != documentURL,
                group: group,
                isCurrent: url.resolvingSymlinksInPath() == documentURL
            )
        }
    }

    private func contentHash(
        for url: URL,
        modified: Date,
        byteCount: Int,
        cache: inout [ContentFingerprint: String],
        order: inout [ContentFingerprint]
    ) -> String? {
        let key = ContentFingerprint(
            path: url.standardizedFileURL.path,
            modified: modified,
            byteCount: byteCount
        )
        if let cached = cache[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return cached
        }

        guard let data = try? Data(contentsOf: url),
              String(data: data, encoding: .utf8) != nil else { return nil }
        let hash = DocumentIO.contentHash(data)
        cache[key] = hash
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > contentHashCacheLimit {
            cache.removeValue(forKey: order.removeFirst())
        }
        return hash
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
        guard let index = siblings.firstIndex(where: {
            $0.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
        }) else {
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
