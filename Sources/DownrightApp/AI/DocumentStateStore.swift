import Foundation
import MarkdownCore
import MarkdownRender

/// Per-document reading state (§8.2, §9.3).
///
/// Long documents behave like books: you get your place back.  The position is
/// stored as a **heading anchor plus an offset into that section**, never as a
/// byte offset — an agent that inserts two paragraphs at the top of the file
/// would otherwise land you two paragraphs off every time.
struct ScrollAnchor: Codable, Equatable {
    /// Slug of the nearest heading at or above the viewport top.
    var headingSlug: String
    /// Index of that heading, as a tiebreak when slugs repeat.
    var headingIndex: Int
    /// Fraction of the way through that section, 0…1.
    var fractionThroughSection: Double

    static let top = ScrollAnchor(headingSlug: "", headingIndex: 0, fractionThroughSection: 0)
}

struct DocumentState: Codable, Equatable {
    var path: String
    /// Content hash of what was on disk when the document was last closed.
    /// Pure disk-state bookkeeping: it moves the instant a write is absorbed,
    /// so it says nothing about what the reader has read.
    var lastSeenHash: String
    /// Content hash of the document as the reader last *finished reviewing* it.
    ///
    /// This is the one hash the app diffs incoming writes against, and the only
    /// one a user action moves.  Keeping it separate from `lastSeenHash` is what
    /// makes "close a window with twelve unreviewed marks and reopen it" show
    /// twelve marks instead of none.  Empty means "never reviewed", in which
    /// case the state the document was first opened in is the baseline.
    var reviewBaselineHash: String
    /// The unreviewed mark set, re-anchored on reopen (§8.2).  Persisted so a
    /// window close is not silently counted as a review.
    var marks: [ChangeTracker.PersistedMark]
    var anchor: ScrollAnchor
    var mode: RenderMode
    var zoomLevel: ZoomLevel
    /// Heading slugs whose sections are folded.
    var foldedHeadings: Set<String>
    /// Source offsets of code blocks the user explicitly expanded or collapsed,
    /// overriding the auto-collapse rule (§5.1).
    var expandedCodeBlocks: Set<Int>
    var collapsedCodeBlocks: Set<Int>
    var lastOpened: Date
    var sidebarVisible: Bool
    var selectionLocation: Int
    var selectionLength: Int
    var splitViewEnabled: Bool

    init(path: String) {
        self.path = path
        self.lastSeenHash = ""
        self.reviewBaselineHash = ""
        self.marks = []
        self.anchor = .top
        self.mode = .live
        self.zoomLevel = .everything
        self.foldedHeadings = []
        self.expandedCodeBlocks = []
        self.collapsedCodeBlocks = []
        self.lastOpened = Date()
        self.sidebarVisible = false
        self.selectionLocation = 0
        self.selectionLength = 0
        self.splitViewEnabled = false
    }

    // Older state files won't have every key; decode leniently so a version
    // bump never costs the user their reading positions.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        lastSeenHash = try c.decodeIfPresent(String.self, forKey: .lastSeenHash) ?? ""
        // A state file written before the review baseline existed has only the
        // disk hash to offer.  Adopting it means the first session after the
        // upgrade shows nothing new, which is honest — it is exactly what the
        // old build already showed — rather than re-marking the whole document.
        reviewBaselineHash = try c.decodeIfPresent(String.self, forKey: .reviewBaselineHash)
            ?? lastSeenHash
        marks = try c.decodeIfPresent([ChangeTracker.PersistedMark].self, forKey: .marks) ?? []
        anchor = try c.decodeIfPresent(ScrollAnchor.self, forKey: .anchor) ?? .top
        // Mode used to persist Read/Source.  The adaptive Document surface is
        // now the only restorable state; Source Focus is always transient.
        _ = try c.decodeIfPresent(RenderMode.self, forKey: .mode)
        mode = .live
        // Structural zoom belonged to the old read-only mode. Restoring it in
        // the editable Document surface makes paragraphs disappear around the
        // caret and looks like data loss. Keep it transient and always reopen
        // a complete document.
        _ = try c.decodeIfPresent(ZoomLevel.self, forKey: .zoomLevel)
        zoomLevel = .everything
        foldedHeadings = try c.decodeIfPresent(Set<String>.self, forKey: .foldedHeadings) ?? []
        expandedCodeBlocks = try c.decodeIfPresent(Set<Int>.self, forKey: .expandedCodeBlocks) ?? []
        collapsedCodeBlocks = try c.decodeIfPresent(Set<Int>.self, forKey: .collapsedCodeBlocks) ?? []
        lastOpened = try c.decodeIfPresent(Date.self, forKey: .lastOpened) ?? Date()
        sidebarVisible = try c.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? false
        selectionLocation = try c.decodeIfPresent(Int.self, forKey: .selectionLocation) ?? 0
        selectionLength = try c.decodeIfPresent(Int.self, forKey: .selectionLength) ?? 0
        splitViewEnabled = try c.decodeIfPresent(Bool.self, forKey: .splitViewEnabled) ?? false
    }
}

/// Entry in the recents list, kept with enough detail to draw a rendered
/// thumbnail without opening the file (§9.3).
struct RecentDocument: Codable, Equatable, Identifiable {
    var id: String { path }
    var path: String
    var displayName: String
    var firstHeading: String
    var lastOpened: Date
    var wordCount: Int
}

final class DocumentStateStore {
    static let shared = DocumentStateStore()

    private let fm = FileManager.default
    private var cache: [String: DocumentState] = [:]
    private var cacheOrder: [String] = []
    private let maximumCachedStates = 256
    private let lock = NSLock()
    private let pruneQueue = DispatchQueue(label: "com.ezzy.downright.state-prune", qos: .utility)

    /// A deleted document keeps its reading position long enough to be
    /// restored from the Trash, without making the state directory a permanent
    /// record of every document ever opened.
    private let abandonedStateMaximumAge: TimeInterval = 30 * 24 * 60 * 60
    private let abandonedStateConfirmationDelay: TimeInterval
    private let supportDirectory: URL
    private let stateDirectory: URL
    private var abandonedCandidates: [String: String] = [:]

    /// `supportDirectory` is injectable so state-pruning tests cannot touch the
    /// user's real reading positions or recents.
    init(
        supportDirectory: URL = AppPaths.supportDirectory,
        abandonedStateConfirmationDelay: TimeInterval = 30
    ) {
        self.supportDirectory = supportDirectory.standardizedFileURL
        self.stateDirectory = self.supportDirectory.appendingPathComponent("state", isDirectory: true)
        self.abandonedStateConfirmationDelay = abandonedStateConfirmationDelay
        AppPaths.ensure(self.stateDirectory)
    }

    /// Drops stale reading state for documents that no longer exist. This is a
    /// launch job: nothing else deletes these files, and doing the directory
    /// walk off the main thread keeps opening a document responsive.
    func schedulePruneAbandonedStates() {
        pruneQueue.async { [self] in
            pruneAbandonedStates()
            // A second, meaningfully separated observation confirms absence
            // without installing a permanent maintenance timer.
            pruneQueue.asyncAfter(deadline: .now() + abandonedStateConfirmationDelay) { [self] in
                pruneAbandonedStates()
            }
        }
    }

    @discardableResult
    func pruneAbandonedStates() -> Int {
        guard let files = try? fm.contentsOfDirectory(
            at: stateDirectory,
            includingPropertiesForKeys: nil
        ) else { return 0 }

        let cutoff = Date().addingTimeInterval(-abandonedStateMaximumAge)
        var removed = 0
        for file in files where file.pathExtension == "json" {
            let key = file.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: file),
                  let state = try? JSONDecoder.snapshotDecoder.decode(DocumentState.self, from: data)
            else {
                _ = lock.withLock { abandonedCandidates.removeValue(forKey: key) }
                continue
            }

            guard state.lastOpened < cutoff else {
                _ = lock.withLock { abandonedCandidates.removeValue(forKey: key) }
                continue
            }
            let presence = state.path.isEmpty
                ? SnapshotStore.PathPresence.absent
                : SnapshotStore.pathPresence(for: state.path)
            guard presence == .absent,
                  (state.path.isEmpty || SnapshotStore.volumeIsMounted(for: state.path)) else {
                _ = lock.withLock { abandonedCandidates.removeValue(forKey: key) }
                continue
            }
            let signature = DocumentIO.contentHash(data)
            let confirmed = lock.withLock {
                guard abandonedCandidates[key] == signature else {
                    abandonedCandidates[key] = signature
                    return false
                }
                return true
            }
            guard confirmed else { continue }
            let didRemove = lock.withLock {
                // A save can refresh this state while the prune is walking.
                // Delete only the exact stale generation we inspected.
                guard (try? Data(contentsOf: file)) == data else { return false }
                do {
                    try fm.removeItem(at: file)
                } catch {
                    return false
                }
                cache.removeValue(forKey: key)
                cacheOrder.removeAll { $0 == key }
                abandonedCandidates.removeValue(forKey: key)
                return true
            }
            if didRemove { removed += 1 }
        }
        return removed
    }

    // MARK: - Per-document state

    func state(for url: URL) -> DocumentState {
        let key = SnapshotStore.documentKey(for: url)
        return lock.withLock {
            if let cached = cache[key] {
                touchCacheKey(key)
                return cached
            }

            let fileURL = stateDirectory.appendingPathComponent(key + ".json")
            var state: DocumentState
            if let data = try? Data(contentsOf: fileURL),
               let decoded = try? JSONDecoder.snapshotDecoder.decode(DocumentState.self, from: data) {
                state = decoded
            } else {
                state = DocumentState(path: url.path)
            }
            state.path = url.path
            storeInCache(state, forKey: key)
            return state
        }
    }

    func save(_ state: DocumentState, for url: URL) {
        let key = SnapshotStore.documentKey(for: url)
        guard let data = try? JSONEncoder.snapshotEncoder.encode(state) else { return }
        let fileURL = stateDirectory.appendingPathComponent(key + ".json")
        lock.withLock {
            storeInCache(state, forKey: key)
            try? data.write(to: fileURL, options: .atomic)
            _ = abandonedCandidates.removeValue(forKey: key)
        }
    }

    // MARK: - Recents

    private var recentsURL: URL { supportDirectory.appendingPathComponent("recents.json") }

    func recents(limit: Int = 30) -> [RecentDocument] {
        guard let data = try? Data(contentsOf: recentsURL),
              let list = try? JSONDecoder.snapshotDecoder.decode([RecentDocument].self, from: data)
        else { return [] }
        var seen = Set<String>()
        let liveDocuments = list.compactMap { recent -> RecentDocument? in
            let canonical = Self.canonicalPath(recent.path)
            guard fm.fileExists(atPath: canonical) else { return nil }
            guard seen.insert(canonical).inserted else { return nil }
            var copy = recent
            copy.path = canonical
            return copy
        }
        return Array(liveDocuments.sorted { $0.lastOpened > $1.lastOpened }.prefix(limit))
    }

    /// Resolves a stored path the same way `AppDelegate.open` identifies a
    /// window, so a file reached through a symlink is the same recent entry
    /// everywhere instead of a duplicate.  Internal so tests can lock the
    /// identity contract with `AppDelegate.open`.
    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    func noteOpened(_ url: URL, document: ParsedDocument) {
        let canonical = Self.canonicalPath(url.path)
        var list = recents(limit: 200).filter {
            Self.canonicalPath($0.path) != canonical
        }
        list.insert(
            RecentDocument(
                path: canonical,
                displayName: url.deletingPathExtension().lastPathComponent,
                firstHeading: document.headings.first?.title ?? "",
                lastOpened: Date(),
                // The caller already parsed this text; `Metrics.metrics(for:)`
                // would reparse it and then tokenize every sentence to compute
                // two figures this row throws away.
                wordCount: Metrics.documentWordCount(document)
            ),
            at: 0
        )
        list = Array(list.prefix(60))
        if let data = try? JSONEncoder.snapshotEncoder.encode(list) {
            try? data.write(to: recentsURL, options: .atomic)
        }
    }

    /// Drops one entry and leaves the rest alone.  Matched on the canonical
    /// path for the same reason `noteOpened` stores one: a file reached through
    /// a symlink is the same recent everywhere, so forgetting it once has to
    /// forget it however it was reached.
    func removeRecent(path: String) {
        let canonical = Self.canonicalPath(path)
        let list = recents(limit: 200).filter { Self.canonicalPath($0.path) != canonical }
        guard let data = try? JSONEncoder.snapshotEncoder.encode(list) else { return }
        try? data.write(to: recentsURL, options: .atomic)
    }

    func clearRecents() {
        try? fm.removeItem(at: recentsURL)
    }

    private func storeInCache(_ state: DocumentState, forKey key: String) {
        cache[key] = state
        touchCacheKey(key)
        while cacheOrder.count > maximumCachedStates {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    private func touchCacheKey(_ key: String) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }
}

// MARK: - Anchoring

enum ScrollAnchoring {
    /// Builds an anchor for a source offset.  Used when the buffer is about to
    /// be replaced under the reader (§8.1) and when closing the document.
    static func anchor(for offset: Int, in document: ParsedDocument) -> ScrollAnchor {
        guard let firstHeading = document.headings.first, offset >= firstHeading.range.location else {
            let preambleLength = document.headings.first?.range.location ?? document.length
            let fraction = preambleLength > 0 ? min(1.0, max(0.0, Double(offset) / Double(preambleLength))) : 0
            return ScrollAnchor(headingSlug: "", headingIndex: 0, fractionThroughSection: fraction)
        }

        var index = 0
        for (i, heading) in document.headings.enumerated() where heading.range.location <= offset {
            index = i
        }
        let heading = document.headings[index]
        let span = max(1, heading.sectionRange.length)
        let within = min(max(0, offset - heading.sectionRange.location), span)
        return ScrollAnchor(
            headingSlug: heading.slug,
            headingIndex: index,
            fractionThroughSection: Double(within) / Double(span)
        )
    }

    /// Resolves an anchor back to a source offset in a possibly-rewritten
    /// document.  Matching by slug first is what makes the position survive an
    /// agent inserting a whole new section above where you were reading.
    static func offset(for anchor: ScrollAnchor, in document: ParsedDocument) -> Int {
        guard !document.headings.isEmpty else {
            return Int(anchor.fractionThroughSection * Double(document.length))
        }
        guard !anchor.headingSlug.isEmpty else {
            let preambleLength = document.headings.first?.range.location ?? document.length
            return Int(anchor.fractionThroughSection * Double(preambleLength))
        }

        let candidates = document.headings.enumerated().filter { $0.element.slug == anchor.headingSlug }
        let heading: HeadingNode
        if let exact = candidates.first(where: { $0.offset == anchor.headingIndex })?.element {
            heading = exact
        } else if let nearest = candidates.min(by: {
            abs($0.offset - anchor.headingIndex) < abs($1.offset - anchor.headingIndex)
        })?.element {
            heading = nearest
        } else if anchor.headingIndex < document.headings.count {
            // The heading is gone entirely — fall back to positional.
            heading = document.headings[anchor.headingIndex]
        } else {
            heading = document.headings[document.headings.count - 1]
        }

        let offset = heading.sectionRange.location
            + Int(anchor.fractionThroughSection * Double(heading.sectionRange.length))
        return min(max(0, offset), document.length)
    }
}
