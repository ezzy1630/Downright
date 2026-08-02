import CryptoKit
import Foundation

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

    /// Defaults from §8.3.
    var maximumAge: TimeInterval = 30 * 24 * 60 * 60
    var maximumBytes: Int = 500 * 1024 * 1024

    private let queue = DispatchQueue(label: "com.unrulyagency.downright.history", qos: .utility)
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
    private var lastPrune: Date = .distantPast

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
            stateByDocument[documentKey] = state
            return nil
        }
        state.newestHash = hash
        stateByDocument[documentKey] = state

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

    func text(forHash hash: String) -> String? {
        let url = objectURL(for: hash)
        guard let compressed = try? Data(contentsOf: url) else { return nil }
        guard let raw = try? (compressed as NSData).decompressed(using: .zlib) as Data else {
            // Objects written before compression, or a truncated write.
            return String(data: compressed, encoding: .utf8)
        }
        return String(data: raw, encoding: .utf8)
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

    /// Total bytes held by the store, for the preferences pane.
    func totalBytes() -> Int {
        guard let e = fm.enumerator(at: objectsDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in e {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    func forget(_ url: URL) {
        let documentKey = Self.documentKey(for: url)
        pendingLock.lock()
        defer { pendingLock.unlock() }
        // Keep a loaded empty state until the queued deletion runs.  A new
        // record immediately after forget must not read the old index again.
        stateByDocument[documentKey] = DocumentState(isLoaded: true)
        queue.async { [self] in
            try? fm.removeItem(at: indexURL(for: url))
            pendingLock.lock()
            defer { pendingLock.unlock() }
            if stateByDocument[documentKey]?.newestHash == nil {
                stateByDocument.removeValue(forKey: documentKey)
            }
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

    /// Drops versions past the age cap, then oldest-first until under the size
    /// cap, then garbage-collects objects no index references any more.
    func prune() {
        let cutoff = Date().addingTimeInterval(-maximumAge)
        var referenced = Set<String>()
        var newestHashes = Set<String>()

        let indexes = (try? fm.contentsOfDirectory(at: indexDirectory, includingPropertiesForKeys: nil)) ?? []
        for indexFile in indexes where indexFile.pathExtension == "json" {
            guard let data = try? Data(contentsOf: indexFile),
                  var index = try? JSONDecoder.snapshotDecoder.decode(Index.self, from: data)
            else { continue }

            // Always keep the newest version even if it is older than the cap:
            // a document you haven't touched in six weeks should still have a
            // "what did it look like before" to compare against.
            let newest = index.versions.last
            index.versions.removeAll { $0.date < cutoff && $0.hash != newest?.hash }
            if index.versions.isEmpty, let newest { index.versions = [newest] }

            if let encoded = try? JSONEncoder.snapshotEncoder.encode(index) {
                try? encoded.write(to: indexFile, options: .atomic)
            }
            referenced.formUnion(index.versions.map(\.hash))
            if let newest = index.versions.last?.hash {
                newestHashes.insert(newest)
            }
        }

        // Size cap: drop the oldest unreferenced-after-trim objects first.
        var objects: [(url: URL, size: Int, date: Date, hash: String)] = []
        if let e = fm.enumerator(at: objectsDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) {
            for case let url as URL in e {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = values.fileSize else { continue }
                objects.append((url, size, values.contentModificationDate ?? .distantPast, url.lastPathComponent))
            }
        }

        for object in objects where !referenced.contains(object.hash) {
            try? fm.removeItem(at: object.url)
        }

        var live = objects.filter { referenced.contains($0.hash) }
        var total = live.reduce(0) { $0 + $1.size }
        guard total > maximumBytes else { return }

        live.sort { $0.date < $1.date }
        var dropped = Set<String>()
        // Keep every document's newest version.  The in-memory reservation
        // cache relies on the index's newest hash remaining durable.
        for object in live where total > maximumBytes && !newestHashes.contains(object.hash) {
            try? fm.removeItem(at: object.url)
            dropped.insert(object.hash)
            total -= object.size
        }
        guard !dropped.isEmpty else { return }

        for indexFile in indexes where indexFile.pathExtension == "json" {
            guard let data = try? Data(contentsOf: indexFile),
                  var index = try? JSONDecoder.snapshotDecoder.decode(Index.self, from: data)
            else { continue }
            index.versions.removeAll { dropped.contains($0.hash) }
            if let encoded = try? JSONEncoder.snapshotEncoder.encode(index) {
                try? encoded.write(to: indexFile, options: .atomic)
            }
        }
    }

    // MARK: - Hashing

    static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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
