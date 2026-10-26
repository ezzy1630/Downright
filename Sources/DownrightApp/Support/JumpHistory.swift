import Foundation

/// Back/forward through jump destinations (§7.1).
///
/// Records outline jumps, followed links, change navigation, and search hits —
/// but deliberately **not** ordinary scrolling, which would fill the stack with
/// noise and make the two-finger swipe useless.
final class JumpHistory {
    struct Entry: Equatable {
        var url: URL?
        var offset: Int
        var label: String
        var anchor: ScrollAnchor? = nil
    }

    private(set) var entries: [Entry] = []
    private var index: Int = -1
    /// Deep enough for a long reading session, bounded so it can't grow without limit.
    private let limit = 100

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < entries.count - 1 }
    var current: Entry? { index >= 0 && index < entries.count ? entries[index] : nil }

    /// Records a jump *away from* `from` *to* `to`.  Both ends are recorded so
    /// going back lands where you were looking, not where you jumped to.
    func record(from: Entry?, to: Entry) {
        if let from, index < 0 || entries.isEmpty {
            entries = [from]
            index = 0
        } else if let from, let current, (current.url != from.url || abs(current.offset - from.offset) > 40) {
            // The reader scrolled since the last recorded position; update the
            // current entry so "back" returns to where they actually were.
            entries[index] = from
        }

        // A new jump truncates the forward stack, as in every browser.
        if index < entries.count - 1 {
            entries.removeSubrange((index + 1)...)
        }
        entries.append(to)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        index = entries.count - 1
    }

    func goBack(accept: (Entry) -> Bool = { _ in true }) -> Entry? {
        guard canGoBack, accept(entries[index - 1]) else { return nil }
        index -= 1
        return entries[index]
    }

    func goForward(accept: (Entry) -> Bool = { _ in true }) -> Entry? {
        guard canGoForward, accept(entries[index + 1]) else { return nil }
        index += 1
        return entries[index]
    }

    func updateCurrent(_ entry: Entry) {
        guard index >= 0, index < entries.count else { return }
        entries[index] = entry
    }

    func clear() {
        entries.removeAll()
        index = -1
    }
}
