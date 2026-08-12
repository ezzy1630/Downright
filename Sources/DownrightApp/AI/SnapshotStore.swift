import Foundation
import MarkdownCore

/// Local time-travel (§8.3).
///
/// Agents don't commit, and git doesn't help you here: by the time you notice
/// the agent replaced a section you wanted, the previous text exists nowhere.
/// So every external write is snapshotted into a content-addressed store,
/// deduplicated by hash — an agent that rewrites a file four times with the
/// same content costs one object.
///
/// Store layout:
/// ```
/// history/objects/<ab>/<hash>       zlib-compressed UTF-8 content
/// history/index/<docKey>.json       ordered version list for one document
/// ```
final class SnapshotStore {
    static let shared = SnapshotStore()

    enum SnapshotKind: String, Codable {
        /// Written by something outside the app — the interesting case.
        case external
        /// Written by us, kept so the timeline is continuous.
        case local
        /// The state at the moment the document was first opened.
        case baseline
    }

    struct VersionRecord: Codable, Identifiable, Equatable {
        var id: String { hash }
        var hash: String
        var date: Date
        var byteCount: Int
        var kind: SnapshotKind

        static func == (a: VersionRecord, b: VersionRecord) -> Bool {
            a.hash == b.hash && a.date == b.date
        }
    }

    private struct Index: Codable {
        var path: String
        var versions: [VersionRecord]
    }

    /// The result of asking for a historical version.
    ///
    /// "Not there" and "there but unreadable" are different answers and the
    /// timeline has to say which: silently handing back mojibake presents a
    /// truncated object as a real version of the user's document.
    enum Content: Equatable {
        case text(String)
        /// No object with that hash — pruned by age or size, or never written.
        case missing
        /// The object exists but does not decompress, does not decode as UTF-8,
        /// or does not hash back to the name it is filed under.
        case corrupt
    }

    /// Defaults from §8.3. Preferences mutate these on the main actor while
    /// pruning runs on the history queue, so the lock owns the complete limits
    /// snapshot as well as the pending-record cache.
    private var storedMaximumAge: TimeInterval = 30 * 24 * 60 * 60
    private var storedMaximumBytes: Int = 500 * 1024 * 1024
    private var storedMaximumBytesPerDocument: Int = 32 * 1024 * 1024
    var maximumAge: TimeInterval {
        get { pendingLock.withLock { storedMaximumAge } }
        set { pendingLock.withLock { storedMaximumAge = newValue } }
    }
    var maximumBytes: Int {
        get { pendingLock.withLock { storedMaximumBytes } }
        set { pendingLock.withLock { storedMaximumBytes = newValue } }
    }
    /// Per-document size cap.
    ///
    /// A single global cap lets one 400 MB document's history evict every other
    /// document's, which defeats the entire point of the store: the file *you*
    /// are reading has to have a yesterday.  Each document is trimmed against
    /// its own budget first, and the global cap is only a backstop.
    var maximumBytesPerDocument: Int {
        get { pendingLock.withLock { storedMaximumBytesPerDocument } }
        set { pendingLock.withLock { storedMaximumBytesPerDocument = newValue } }
    }

    /// What a prune removed, so a document can say "older versions were
    /// dropped" instead of quietly having fewer entries than last time.
    struct PruneReport: Equatable {
        /// Versions dropped, keyed by document key.
        var droppedVersions: [String: Int] = [:]
        /// Bytes reclaimed from the object store.
        var freedBytes: Int = 0
        var isEmpty: Bool { droppedVersions.isEmpty }
    }

    private let queue = DispatchQueue(label: "com.ezzy.downright.history", qos: .utility)
    private let fm = FileManager.default
    private let pendingLock = NSLock()
    private struct DocumentState {
        var newestHash: String?
        var isLoaded: Bool

        init(newestHash: String? = nil, isLoaded: Bool = false) {
            self.newestHash = newestHash
            self.isLoaded = isLoaded
        }
    }

    /// The lock owns this cache.  A hash is reserved before the disk write is
    /// queued, so a second record call cannot race the first index update.
    private var stateByDocument: [String: DocumentState] = [:]
    private var stateOrder: [String] = []
    private let maximumCachedDocuments = 512
    private var lastPrune: Date = .distantPast
    /// Guarded by `pendingLock`.  Accumulates across prunes until a document
    /// reads and acknowledges its own count.
    private var evictedVersionsByDocument: [String: Int] = [:]
    private var lastReport = PruneReport()

    private init() {
        AppPaths.ensure(AppPaths.historyDirectory)
        AppPaths.ensure(objectsDirectory)
        AppPaths.ensure(indexDirectory)
    }

    private var objectsDirectory: URL { AppPaths.historyDirectory.appendingPathComponent("objects", isDirectory: true) }
    private var indexDirectory: URL { AppPaths.historyDirectory.appendingPathComponent("index", isDirectory: true) }

    // MARK: - Recording

    /// Records `text` as a version of `url`.  Returns nil when the content is
    /// identical to the newest version already recorded, which is the common
    /// case for a save that changed nothing.
    @discardableResult
    func record(_ text: String, for url: URL, kind: SnapshotKind) -> VersionRecord? {
        let hash = Self.hash(text)
        let documentKey = Self.documentKey(for: url)
        pendingLock.lock()
        defer { pendingLock.unlock() }

        var state = stateByDocument[documentKey] ?? DocumentState()
        if !state.isLoaded {
            state.newestHash = loadIndex(for: url).versions.last?.hash
            state.isLoaded = true
        }
        guard state.newestHash != hash else {
            storeState(state, forKey: documentKey)
            return nil
        }
        state.newestHash = hash
        storeState(state, forKey: documentKey)

        let data = Data(text.utf8)
        let record = VersionRecord(hash: hash, date: Date(), byteCount: data.count, kind: kind)

        queue.async { [self] in
            writeObjectIfNeeded(hash: hash, data: data)
            var idx = loadIndex(for: url)
            guard idx.versions.last?.hash != hash else { return }
            idx.versions.append(record)
            saveIndex(idx, for: url)
            pruneIfDue()
        }
        return record
    }

    // MARK: - Reading

    func versions(for url: URL) -> [VersionRecord] {
        loadIndex(for: url).versions
    }

    func text(for record: VersionRecord) -> String? {
        text(forHash: record.hash)
    }

    /// Convenience for callers that treat "gone" and "broken" alike.  Prefer
    /// `content(forHash:)` anywhere the difference is visible to the user.
    func text(forHash hash: String) -> String? {
        guard case .text(let text) = content(forHash: hash) else { return nil }
        return text
    }

    func content(for record: VersionRecord) -> Content {
        content(forHash: record.hash)
    }

    /// Reads an object and verifies it.
    ///
    /// The store is content-addressed, so the file name *is* the checksum: the
    /// only trustworthy test of "did this survive" is hashing what came back.
    /// That is also what separates a legitimate pre-compression object (raw
    /// UTF-8, hashes correctly) from a truncated compressed one (decompression
    /// fails, and the bytes read as UTF-8 mojibake that hashes to nothing).
    func content(forHash hash: String) -> Content {
        guard !hash.isEmpty else { return .missing }
        let url = objectURL(for: hash)
        guard let stored = try? Data(contentsOf: url) else { return .missing }

        if let raw = try? (stored as NSData).decompressed(using: .zlib) as Data,
           let text = String(data: raw, encoding: .utf8),
           Self.hash(text) == hash {
            return .text(text)
        }
        // Objects written before compression are raw UTF-8.
        if let text = String(data: stored, encoding: .utf8), Self.hash(text) == hash {
            return .text(text)
        }
        return .corrupt
    }

    /// Waits for all writes queued before this call.  Used by tests and
    /// lifecycle code that needs a durable handoff without a timing guess.
    func waitForPendingWrites() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                continuation.resume()
            }
        }
    }

    /// Runs pruning on the same serial executor as object and index writes.
    /// This prevents launch maintenance from deleting an object in the narrow
    /// window between its write and the matching index append.
    func schedulePrune() {
        queue.async { [self] in
            _ = prune()
        }
    }

    /// Total bytes held by the store, for the preferences pane.
    func totalBytes() -> Int {
        guard let e = fm.enumerator(at: objectsDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in e {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    /// Drops one document's entire history — the "Forget this document's
    /// history" action.  The index goes immediately; the objects go on the
    /// sweep that follows, because another document may share them.
    func forget(_ url: URL) {
        let documentKey = Self.documentKey(for: url)
        pendingLock.lock()
        // Keep a loaded empty state until the queued deletion runs.  A new
        // record immediately after forget must not read the old index again.
        storeState(DocumentState(isLoaded: true), forKey: documentKey)
        evictedVersionsByDocument.removeValue(forKey: documentKey)
        pendingLock.unlock()

        queue.async { [self] in
            try? fm.removeItem(at: indexURL(for: url))
            pendingLock.lock()
            if stateByDocument[documentKey]?.newestHash == nil {
                stateByDocument.removeValue(forKey: documentKey)
                stateOrder.removeAll { $0 == documentKey }
            }
            pendingLock.unlock()
            // Deleting the index only unreferences the objects.  Sweep now so
            // "forget" actually reclaims the disk the user asked us to give
            // back, rather than waiting up to five minutes for the next write.
            collectUnreferencedObjects()
        }
    }

    /// This cache only coalesces writes. Evicting an old entry is safe because
    /// the next write reloads its compact index from disk.
    private func storeState(_ state: DocumentState, forKey key: String) {
        stateByDocument[key] = state
        stateOrder.removeAll { $0 == key }
        stateOrder.append(key)
        while stateOrder.count > maximumCachedDocuments {
            let evicted = stateOrder.removeFirst()
            stateByDocument.removeValue(forKey: evicted)
        }
    }

    // MARK: - Object storage

    private func objectURL(for hash: String) -> URL {
        objectsDirectory
            .appendingPathComponent(String(hash.prefix(2)), isDirectory: true)
            .appendingPathComponent(hash)
    }

    private func writeObjectIfNeeded(hash: String, data: Data) {
        let url = objectURL(for: hash)
        guard !fm.fileExists(atPath: url.path) else { return }
        AppPaths.ensure(url.deletingLastPathComponent())
        let payload = (try? (data as NSData).compressed(using: .zlib) as Data) ?? data
        try? payload.write(to: url, options: .atomic)
    }

    // MARK: - Index

    private func indexURL(for url: URL) -> URL {
        indexDirectory.appendingPathComponent(Self.documentKey(for: url) + ".json")
    }

    private func loadIndex(for url: URL) -> Index {
        guard let data = try? Data(contentsOf: indexURL(for: url)),
              let index = try? JSONDecoder.snapshotDecoder.decode(Index.self, from: data)
        else { return Index(path: url.path, versions: []) }
        return index
    }

    private func saveIndex(_ index: Index, for url: URL) {
        guard let data = try? JSONEncoder.snapshotEncoder.encode(index) else { return }
        try? data.write(to: indexURL(for: url), options: .atomic)
    }

    // MARK: - Pruning

    private func pruneIfDue() {
        guard Date().timeIntervalSince(lastPrune) > 300 else { return }
        lastPrune = Date()
        prune()
    }

    /// Trims every document against the age cap and its **own** size budget,
    /// then applies the global cap as a backstop, then garbage-collects objects
    /// no index references any more.
    ///
    /// Per-document first is the whole point: the previous global-only pass
    /// walked all objects oldest-first, so one document with a long history
    /// could silently evict every other document's past before touching its
    /// own.  Whatever is dropped is recorded per document so the timeline can
    /// say so out loud.
    @discardableResult
    private func prune() -> PruneReport {
        let limits = pendingLock.withLock {
            (storedMaximumAge, storedMaximumBytes, storedMaximumBytesPerDocument)
        }
        let cutoff = Date().addingTimeInterval(-limits.0)
        var report = PruneReport()
        var referenced = Set<String>()
        var newestHashes = Set<String>()

        let indexes = (try? fm.contentsOfDirectory(at: indexDirectory, includingPropertiesForKeys: nil)) ?? []
        for indexFile in indexes where indexFile.pathExtension == "json" {
            guard let data = try? Data(contentsOf: indexFile),
                  var index = try? JSONDecoder.snapshotDecoder.decode(Index.self, from: data)
            else { continue }
            let documentKey = indexFile.deletingPathExtension().lastPathComponent
            let before = index.versions.count

            // Always keep the newest version even if it is older than the cap:
            // a document you haven't touched in six weeks should still have a
            // "what did it look like before" to compare against.
            let newest = index.versions.last
            index.versions.removeAll { $0.date < cutoff && $0.hash != newest?.hash }
            if index.versions.isEmpty, let newest { index.versions = [newest] }

            // Per-document size budget, oldest first, newest always kept.
            var total = index.versions.reduce(0) { $0 + $1.byteCount }
            while total > limits.2, index.versions.count > 1 {
                total -= index.versions.removeFirst().byteCount
            }

            let dropped = before - index.versions.count
            if dropped > 0 { report.droppedVersions[documentKey, default: 0] += dropped }

            if let encoded = try? JSONEncoder.snapshotEncoder.encode(index) {
                try? encoded.write(to: indexFile, options: .atomic)
            }
            referenced.formUnion(index.versions.map(\.hash))
            if let newest = index.versions.last?.hash {
                newestHashes.insert(newest)
            }
        }

        var objects = objectInventory()
        for object in objects where !referenced.contains(object.hash) {
            try? fm.removeItem(at: object.url)
            report.freedBytes += object.size
        }

        var live = objects.filter { referenced.contains($0.hash) }
        var total = live.reduce(0) { $0 + $1.size }
        guard total > limits.1 else {
            recordPrune(report)
            return report
        }

        live.sort { $0.date < $1.date }
        var dropped = Set<String>()
        // Keep every document's newest version.  The in-memory reservation
        // cache relies on the index's newest hash remaining durable.
        for object in live where total > limits.1 && !newestHashes.contains(object.hash) {
            try? fm.removeItem(at: object.url)
            dropped.insert(object.hash)
            report.freedBytes += object.size
            total -= object.size
        }
        objects = []
        guard !dropped.isEmpty else {
            recordPrune(report)
            return report
        }

        for indexFile in indexes where indexFile.pathExtension == "json" {
            guard let data = try? Data(contentsOf: indexFile),
                  var index = try? JSONDecoder.snapshotDecoder.decode(Index.self, from: data)
            else { continue }
            let documentKey = indexFile.deletingPathExtension().lastPathComponent
            let before = index.versions.count
            index.versions.removeAll { dropped.contains($0.hash) }
            let removed = before - index.versions.count
            if removed > 0 { report.droppedVersions[documentKey, default: 0] += removed }
            if let encoded = try? JSONEncoder.snapshotEncoder.encode(index) {
                try? encoded.write(to: indexFile, options: .atomic)
            }
        }
        recordPrune(report)
        return report
    }

    /// Removes objects no index mentions.  Split out of `prune()` so `forget`
    /// can reclaim one document's disk without a full age/size pass.
    private func collectUnreferencedObjects() {
        var referenced = Set<String>()
        let indexes = (try? fm.contentsOfDirectory(at: indexDirectory, includingPropertiesForKeys: nil)) ?? []
        for indexFile in indexes where indexFile.pathExtension == "json" {
            guard let data = try? Data(contentsOf: indexFile),
                  let index = try? JSONDecoder.snapshotDecoder.decode(Index.self, from: data)
            else { continue }
            referenced.formUnion(index.versions.map(\.hash))
        }
        for object in objectInventory() where !referenced.contains(object.hash) {
            try? fm.removeItem(at: object.url)
        }
    }

    private func objectInventory() -> [(url: URL, size: Int, date: Date, hash: String)] {
        var objects: [(url: URL, size: Int, date: Date, hash: String)] = []
        guard let e = fm.enumerator(
            at: objectsDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return objects }
        for case let url as URL in e {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { continue }
            objects.append((url, size, values.contentModificationDate ?? .distantPast, url.lastPathComponent))
        }
        return objects
    }

    private func recordPrune(_ report: PruneReport) {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        lastReport = report
        for (key, count) in report.droppedVersions {
            evictedVersionsByDocument[key, default: 0] += count
        }
    }

    // MARK: - Hashing

    static func hash(_ text: String) -> String {
        DocumentIO.contentHash(text)
    }

    static func hash(_ data: Data) -> String {
        DocumentIO.contentHash(data)
    }

    static func documentKey(for url: URL) -> String {
        hash(url.resolvingSymlinksInPath().path)
    }
}

extension JSONDecoder {
    static let snapshotDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension JSONEncoder {
    static let snapshotEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
