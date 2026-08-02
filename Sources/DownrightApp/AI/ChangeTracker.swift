import Foundation
import MarkdownCore

/// Change marks for "what changed while I was reading" (§8.1).
///
/// Marks are held separately from the text storage so they survive a reparse
/// and so the fade is a property of the mark rather than of the document.  They
/// are expressed as ranges in the current buffer and shifted as the user types,
/// because a mark that drifts is worse than no mark at all.
final class ChangeTracker {
    struct Mark: Identifiable {
        let id = UUID()
        var kind: ChangeKind
        /// Range in the current buffer.
        var range: NSRange
        /// Word-level ranges inside `range` that differ, for highlighting
        /// changed words inside rendered prose rather than as +/- lines.
        var wordRanges: [NSRange]
        var created: Date
        var visited: Bool
    }

    /// Marks fade after ten minutes or on visit (§8.1).
    var lifetime: TimeInterval = 600

    private(set) var marks: [Mark] = []
    /// Fires when the mark set changes in a way that needs a redraw.
    var onChange: (() -> Void)?

    private var fadeTimer: Timer?

    deinit { fadeTimer?.invalidate() }

    var isEmpty: Bool { marks.isEmpty }
    var count: Int { marks.count }

    /// Marks that should still be drawn.
    var visibleMarks: [Mark] {
        let cutoff = Date().addingTimeInterval(-lifetime)
        return marks.filter { !$0.visited && $0.created > cutoff }
    }

    /// Number of changed *blocks*, which is what the conflict bar reports.
    var changedBlockCount: Int { marks.count }

    // MARK: - Applying a diff

    func apply(hunks: [ChangeHunk], replacingExisting: Bool = true) {
        let now = Date()
        let new = hunks.map {
            Mark(kind: $0.kind, range: $0.newRange, wordRanges: $0.wordRanges, created: now, visited: false)
        }
        marks = replacingExisting ? new : (marks + new)
        marks.sort { $0.range.location < $1.range.location }
        scheduleFadeCheck()
        onChange?()
    }

    func clear() {
        guard !marks.isEmpty else { return }
        marks.removeAll()
        fadeTimer?.invalidate()
        fadeTimer = nil
        onChange?()
    }

    // MARK: - Staying valid under editing

    /// Adjusts marks for a local edit so they keep pointing at the same text.
    /// A mark whose range the edit overlaps is dropped: once you have rewritten
    /// the changed text yourself, calling it "changed by the agent" is a lie.
    func adjust(forEditIn range: NSRange, delta: Int) {
        guard !marks.isEmpty else { return }
        let before = marks.count
        marks = marks.compactMap { mark in
            var mark = mark
            if mark.range.upperBound <= range.location {
                return mark
            }
            if mark.range.location >= range.upperBound {
                mark.range.location += delta
                mark.wordRanges = mark.wordRanges.map {
                    NSRange(location: $0.location + delta, length: $0.length)
                }
                return mark
            }
            return nil  // overlapped by the edit
        }
        if marks.count != before { onChange?() }
    }

    // MARK: - Navigation (§7.2 `[` / `]`, ⌥↑ / ⌥↓)

    func next(after offset: Int) -> Mark? {
        marks.first { $0.range.location > offset } ?? marks.first
    }

    func previous(before offset: Int) -> Mark? {
        marks.last { $0.range.upperBound < offset } ?? marks.last
    }

    func mark(at offset: Int) -> Mark? {
        marks.first { $0.range.touches(offset: offset) }
    }

    func markVisited(_ id: UUID) {
        guard let index = marks.firstIndex(where: { $0.id == id }), !marks[index].visited else { return }
        marks[index].visited = true
        onChange?()
    }

    /// Ranges to decorate, grouped by kind, for the decorator and the density
    /// gutter to consume without knowing about `Mark`.
    func ranges(of kind: ChangeKind) -> [NSRange] {
        visibleMarks.filter { $0.kind == kind }.map(\.range)
    }

    // MARK: - Fading

    private func scheduleFadeCheck() {
        fadeTimer?.invalidate()
        guard !marks.isEmpty else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let cutoff = Date().addingTimeInterval(-self.lifetime)
            let stale = self.marks.contains { !$0.visited && $0.created <= cutoff }
            if stale { self.onChange?() }
            if self.marks.allSatisfy({ $0.visited || $0.created <= cutoff }) {
                self.fadeTimer?.invalidate()
                self.fadeTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }
}
