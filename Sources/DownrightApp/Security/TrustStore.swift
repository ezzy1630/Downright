import Foundation

protocol TrustStorePersistence: AnyObject {
    func load() throws -> [TrustGrant]
    func save(_ grants: [TrustGrant]) throws
}

final class InMemoryTrustStorePersistence: TrustStorePersistence {
    private(set) var values: [TrustGrant]

    init(_ values: [TrustGrant] = []) { self.values = values }
    func load() throws -> [TrustGrant] { values }
    func save(_ grants: [TrustGrant]) throws { values = grants }
}

private final class JSONTrustStorePersistence: TrustStorePersistence {
    private let url: URL

    init(url: URL) { self.url = url }

    func load() throws -> [TrustGrant] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([TrustGrant].self, from: Data(contentsOf: url))
    }

    func save(_ grants: [TrustGrant]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(grants)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}

/// Persisted grants are canonical path values only.  The store is injected in
/// tests and can be replaced by an app host without changing policy logic.
final class TrustStore {
    static let shared = TrustStore(
        persistence: JSONTrustStorePersistence(url: AppPaths.supportDirectory.appendingPathComponent("trust.json"))
    )

    private let persistence: TrustStorePersistence
    private var values: [TrustGrant]
    private var loadFailed = false
    private let lock = NSLock()

    init(persistence: TrustStorePersistence) {
        self.persistence = persistence
        do {
            self.values = try persistence.load()
        } catch {
            self.values = []
            self.loadFailed = true
        }
    }

    func grants() -> [TrustGrant] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    func policy(state: DocumentTrustState = .standard) -> DocumentTrust {
        DocumentTrust(state: state, grants: grants())
    }

    func state(for documentURL: URL?) -> DocumentTrustState {
        guard let documentURL, let document = DocumentTrust.canonicalFilePath(documentURL) else { return .standard }
        let trusted = grants().contains { grant in
            grant.scope == .folder && DocumentTrust.isWithin(document, URL(fileURLWithPath: grant.canonicalPath))
        }
        return trusted ? .trustedFolder : .standard
    }

    @discardableResult
    func grant(scope: TrustScope, path: URL, effects: Set<TrustEffect>) -> Bool {
        guard let canonical = DocumentTrust.canonicalFilePath(path) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard !loadFailed else { return false }
        let previous = values
        let existing = values.first { $0.scope == scope && $0.canonicalPath == canonical.path }
        values.removeAll { $0.scope == scope && $0.canonicalPath == canonical.path }
        // A new grant extends the effects already allowed for this path rather
        // than replacing them: granting editor-launch after a folder-read must
        // not silently revoke the read the user consented to earlier.
        values.append(TrustGrant(
            scope: scope,
            canonicalPath: canonical.path,
            effects: effects.union(existing?.effects ?? [])
        ))
        // Keep mutation and persistence ordered. Unlocking before the save
        // lets concurrent callers write snapshots in reverse order, leaving
        // trust.json stale even though the in-memory grants are current.
        do {
            try persistence.save(values)
            return true
        } catch {
            values = previous
            return false
        }
    }

    @discardableResult
    func revoke(scope: TrustScope, path: URL) -> Bool {
        guard let canonical = DocumentTrust.canonicalFilePath(path) else { return false }
        lock.lock()
        defer { lock.unlock() }
        values.removeAll { $0.scope == scope && $0.canonicalPath == canonical.path }
        guard !loadFailed else { return false }
        do {
            try persistence.save(values)
            return true
        } catch {
            // Revocation is fail-closed for this process even when persistence
            // fails; callers surface that the durable file needs attention.
            return false
        }
    }
}
