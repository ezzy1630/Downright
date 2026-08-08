import Foundation

protocol TrustStorePersistence: AnyObject {
    func load() -> [TrustGrant]
    func save(_ grants: [TrustGrant])
}

final class InMemoryTrustStorePersistence: TrustStorePersistence {
    private(set) var values: [TrustGrant]

    init(_ values: [TrustGrant] = []) { self.values = values }
    func load() -> [TrustGrant] { values }
    func save(_ grants: [TrustGrant]) { values = grants }
}

private final class JSONTrustStorePersistence: TrustStorePersistence {
    private let url: URL

    init(url: URL) { self.url = url }

    func load() -> [TrustGrant] {
        guard let data = try? Data(contentsOf: url),
              let grants = try? JSONDecoder().decode([TrustGrant].self, from: data)
        else { return [] }
        return grants
    }

    func save(_ grants: [TrustGrant]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(grants) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
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
    private let lock = NSLock()

    init(persistence: TrustStorePersistence) {
        self.persistence = persistence
        self.values = persistence.load()
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
        let grant = TrustGrant(scope: scope, canonicalPath: canonical.path, effects: effects)
        lock.lock()
        defer { lock.unlock() }
        values.removeAll { $0.scope == scope && $0.canonicalPath == canonical.path }
        values.append(grant)
        // Keep mutation and persistence ordered. Unlocking before the save
        // lets concurrent callers write snapshots in reverse order, leaving
        // trust.json stale even though the in-memory grants are current.
        persistence.save(values)
        return true
    }

    func revoke(scope: TrustScope, path: URL) {
        guard let canonical = DocumentTrust.canonicalFilePath(path) else { return }
        lock.lock()
        defer { lock.unlock() }
        values.removeAll { $0.scope == scope && $0.canonicalPath == canonical.path }
        persistence.save(values)
    }
}
