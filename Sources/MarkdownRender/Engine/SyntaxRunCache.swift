import Foundation

/// Memoises `SyntaxHighlighter` output.
///
/// Highlighting is the one genuinely expensive step in decoration, and a
/// keystroke in a paragraph must never re-lex the code blocks around it.  The
/// cache is keyed by content, so a code block that moves because text above it
/// changed is still a hit (§3.5, §12).
final class SyntaxRunCache {
    private struct Key: Hashable {
        var language: String
        var length: Int
        var hash: Int
    }

    private struct Entry {
        var code: String
        var runs: [SyntaxRun]
        var stamp: UInt64
    }

    private var entries: [Key: Entry] = [:]
    private var stamp: UInt64 = 0
    private let capacity: Int
    /// Decoration normally runs on the main thread, but the cache outlives a
    /// single decorate pass and the DR-bench exercises it standalone; a cheap
    /// uncontended lock keeps a future off-main highlight from corrupting the
    /// dict rather than trusting that invariant forever.
    private let lock = NSLock()

    init(capacity: Int = 256) { self.capacity = capacity }

    func runs(for code: String, language: String?, highlighter: SyntaxHighlighter) -> [SyntaxRun] {
        let key = Key(language: language ?? "", length: (code as NSString).length, hash: code.hashValue)
        lock.lock()
        defer { lock.unlock() }
        stamp &+= 1
        // The stored code is compared, not trusted to the hash — a collision
        // would otherwise colour one block with another's grammar.
        if var hit = entries[key], hit.code == code {
            hit.stamp = stamp
            entries[key] = hit
            return hit.runs
        }
        let runs = highlighter.highlight(code, language: language)
        entries[key] = Entry(code: code, runs: runs, stamp: stamp)
        if entries.count > capacity { evict() }
        return runs
    }

    func removeAll() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func evict() {
        // Drop the least recently used quarter in one pass; amortised cheaper
        // than maintaining a linked list for a cache this small.
        let victims = entries.sorted { $0.value.stamp < $1.value.stamp }.prefix(capacity / 4)
        for (key, _) in victims { entries.removeValue(forKey: key) }
    }
}
