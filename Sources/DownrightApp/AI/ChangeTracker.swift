import Foundation
import MarkdownCore

/// Change marks for "what changed while I was reading" (§8.1).
///
/// Marks are **reviewable state, not notifications**.  Everything in this file
/// follows from that one sentence:
///
/// - Visiting a mark dims it; only the user finishing review removes it.  A
///   highlight that disappears the instant you arrive at it has told you a
///   change exists and then hidden which change it was.
/// - A mark is visited on *departure* — when it leaves the viewport, or after a
///   dwell on screen — because scrolling past something is not reading it.
/// - The whole set survives a close/reopen cycle (`persistedMarks`), so closing
///   a window is not the same as saying "I read all twelve of those".
///
/// Marks are held separately from the text storage so they survive a reparse
/// and so the fade is a property of the mark rather than of the document.  They
/// are expressed as ranges in the current buffer and shifted as the user types,
/// because a mark that drifts is worse than no mark at all.
final class ChangeTracker {
    struct Mark: Identifiable, Equatable {
        var id = UUID()
        var kind: ChangeKind
        /// Range in the current buffer.  Never empty for a deletion: see
        /// `TextDiff.anchorRange(for:inNewTextOfLength:)`.
        var range: NSRange
        /// Word-level ranges inside `range` that differ, for highlighting
        /// changed words inside rendered prose rather than as +/- lines.
        /// Populated for insertions as well as modifications.
        var wordRanges: [NSRange]
        /// The bytes the write removed.  Non-empty only for `.deleted`, where
        /// there is nothing in the new text to point at and the UI has to draw
        /// the missing text itself.
        var deletedText: String
        var created: Date
        /// Dimmed rather than removed.  Still drawn, still navigable.
        var visited: Bool
        /// First time this mark was reported inside the viewport, for the dwell
        /// rule.  Transient: not persisted, because "seen in a previous
        /// session" is exactly the claim this type refuses to make.
        var firstSeen: Date?

        init(
            id: UUID = UUID(),
            kind: ChangeKind,
            range: NSRange,
            wordRanges: [NSRange] = [],
            deletedText: String = "",
            created: Date = Date(),
            visited: Bool = false,
            firstSeen: Date? = nil
        ) {
            self.id = id
            self.kind = kind
            self.range = range
            self.wordRanges = wordRanges
            self.deletedText = deletedText
            self.created = created
            self.visited = visited
            self.firstSeen = firstSeen
        }
    }

    /// Marks fade after ten minutes or on visit (§8.1).
    var lifetime: TimeInterval = 600
    /// How long a mark has to sit in the viewport before it counts as read.
    var dwell: TimeInterval = 1.5

    /// Everything the tracker holds, unread and visited alike.  **This is the
    /// decorator's input**: visited marks are drawn dimmed, not dropped.
    private(set) var marks: [Mark] = []
    /// Fires when the mark set changes in a way that needs a redraw.
    var onChange: (() -> Void)?
    /// Fires when the user finished reviewing (`clear()`), so the document can
    /// advance its review baseline.  `reset()` deliberately does not fire it:
    /// tearing a document down is not a review.
    var onReviewed: (() -> Void)?

    private var fadeTimer: Timer?

    deinit { fadeTimer?.invalidate() }

    var isEmpty: Bool { marks.isEmpty }
    var count: Int { marks.count }

    /// Marks the reader has not looked at yet.  For counts and summaries — the
    /// "12 unread changes" number — not for drawing.
    var unreadMarks: [Mark] {
        let cutoff = Date().addingTimeInterval(-lifetime)
        return marks.filter { !$0.visited && $0.created > cutoff }
    }

    /// Historical name for `unreadMarks`, kept because callers that genuinely
    /// want only-unvisited read better this way.  Anything that *draws* should
    /// use `marks` and dim on `Mark.visited`.
    var visibleMarks: [Mark] { unreadMarks }

    var unreadCount: Int { unreadMarks.count }

    /// Number of changed *blocks*, which is what the conflict bar reports.
    var changedBlockCount: Int { marks.count }

    // MARK: - Applying a diff

    /// Replaces the mark set from a fresh diff.
    ///
    /// `newText` and `oldText` are the two sides of that diff.  They are needed
    /// because the hunks alone are not enough to draw a deletion: the anchor has
    /// to be clamped into the new text, and the removed bytes have to be lifted
    /// out of the old one.
    ///
    /// Review progress is carried across: a mark whose kind and range are
    /// unchanged keeps its identity, its creation date, and its visited flag.
    /// That is what lets an agent write five times in three seconds without
    /// resetting the reader's place in the review.
    func apply(
        hunks: [ChangeHunk],
        newText: String = "",
        oldText: String = "",
        replacingExisting: Bool = true
    ) {
        let now = Date()
        let newLength = (newText as NSString).length
        let oldNS = oldText as NSString
        let carried = Dictionary(
            marks.map { (MarkIdentity($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let fresh = hunks.map { hunk -> Mark in
            let range = newText.isEmpty
                ? hunk.newRange
                : TextDiff.anchorRange(for: hunk, inNewTextOfLength: newLength)
            let deleted = hunk.kind == .deleted && hunk.oldRange.upperBound <= oldNS.length
                ? oldNS.substring(with: hunk.oldRange)
                : ""
            var mark = Mark(
                kind: hunk.kind, range: range, wordRanges: hunk.wordRanges,
                deletedText: deleted, created: now
            )
            if let previous = carried[MarkIdentity(mark)] {
                mark.id = previous.id
                mark.created = previous.created
                mark.visited = previous.visited
                mark.firstSeen = previous.firstSeen
            }
            return mark
        }

        marks = replacingExisting ? fresh : (marks + fresh)
        marks.sort { $0.range.location < $1.range.location }
        scheduleFadeCheck()
        onChange?()
    }

    /// The user finished reviewing: drop every mark and let the document move
    /// its review baseline forward.
    func clear() {
        let hadMarks = !marks.isEmpty
        marks.removeAll()
        fadeTimer?.invalidate()
        fadeTimer = nil
        if hadMarks { onChange?() }
        onReviewed?()
    }

    /// Drop every mark because the *document* went away — closing a window,
    /// opening a different file in it.  Never advances the review baseline:
    /// the reader still has not read those changes.
    func reset() {
        guard !marks.isEmpty else { return }
        marks.removeAll()
        fadeTimer?.invalidate()
        fadeTimer = nil
        onChange?()
    }

    // MARK: - Persistence (§8.2)

    struct PersistedRange: Codable, Equatable {
        var location: Int
        var length: Int

        init(_ range: NSRange) {
            location = range.location
            length = range.length
        }

        var range: NSRange { NSRange(location: location, length: length) }
    }

    /// A mark on disk.  `kind` travels as its raw string: a serialisation
    /// boundary is the one place a string flag belongs, and it keeps
    /// `ChangeKind` free of a retroactive `Codable` conformance.
    struct PersistedMark: Codable, Equatable {
        var id: UUID
        var kind: String
        var range: PersistedRange
        var wordRanges: [PersistedRange]
        var deletedText: String
        var created: Date
        var visited: Bool
    }

    var persistedMarks: [PersistedMark] {
        marks.map {
            PersistedMark(
                id: $0.id,
                kind: $0.kind.rawValue,
                range: PersistedRange($0.range),
                wordRanges: $0.wordRanges.map(PersistedRange.init),
                deletedText: $0.deletedText,
                created: $0.created,
                visited: $0.visited
            )
        }
    }

    /// Re-anchors persisted marks onto a freshly computed set.
    ///
    /// On reopen the truthful mark set is whatever the baseline-versus-disk
    /// diff produces; what the state file adds is the reader's *progress*
    /// through it.  A stored mark claims a computed one when both describe the
    /// same kind of edit over the same bytes — exact when the file has not moved
    /// since the window closed, and correctly silent when it has.
    func merge(persisted: [PersistedMark]) {
        guard !persisted.isEmpty, !marks.isEmpty else { return }
        let stored = Dictionary(
            persisted.map { ("\($0.kind):\($0.range.location):\($0.range.length)", $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var changed = false
        for index in marks.indices {
            let mark = marks[index]
            let key = "\(mark.kind.rawValue):\(mark.range.location):\(mark.range.length)"
            guard let match = stored[key] else { continue }
            marks[index].id = match.id
            marks[index].created = match.created
            marks[index].visited = match.visited
            changed = changed || match.visited
        }
        if changed { onChange?() }
    }

    /// Re-anchors persisted marks into a document of `textLength` characters.
    /// A mark that no longer fits is dropped rather than clamped: a highlight
    /// over the wrong words is worse than a missing one.
    func restore(_ persisted: [PersistedMark], textLength: Int) {
        marks = persisted.compactMap { stored in
            guard let kind = ChangeKind(rawValue: stored.kind) else { return nil }
            let range = stored.range.range
            guard range.location >= 0, range.upperBound <= textLength else { return nil }
            return Mark(
                id: stored.id,
                kind: kind,
                range: range,
                wordRanges: stored.wordRanges.map(\.range).filter { $0.upperBound <= textLength },
                deletedText: stored.deletedText,
                created: stored.created,
                visited: stored.visited
            )
        }
        marks.sort { $0.range.location < $1.range.location }
        scheduleFadeCheck()
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

    /// Explicit "I have read this one".  **Not** to be called on arrival at a
    /// mark — see `noteVisibleRange(_:now:)`.
    func markVisited(_ id: UUID) {
        guard let index = marks.firstIndex(where: { $0.id == id }), !marks[index].visited else { return }
        marks[index].visited = true
        onChange?()
    }

    /// Reports what the reader can currently see, in source offsets.
    ///
    /// A mark becomes visited when it has been on screen for `dwell`, or when
    /// it leaves the viewport having been on screen at all.  Both rules say the
    /// same thing: arriving at a change is not reviewing it, and moving on from
    /// one is.
    func noteVisibleRange(_ visible: NSRange, now: Date = Date()) {
        guard !marks.isEmpty else { return }
        var changed = false
        for index in marks.indices {
            let isOnScreen = NSIntersectionRange(marks[index].range, visible).length > 0
                || marks[index].range.touches(offset: visible.location)
            if isOnScreen {
                guard !marks[index].visited else { continue }
                guard let seen = marks[index].firstSeen else {
                    marks[index].firstSeen = now
                    continue
                }
                if now.timeIntervalSince(seen) >= dwell {
                    marks[index].visited = true
                    changed = true
                }
            } else if marks[index].firstSeen != nil, !marks[index].visited {
                marks[index].visited = true
                changed = true
            }
        }
        if changed { onChange?() }
    }

    /// Ranges to decorate, grouped by kind, for the decorator and the density
    /// gutter to consume without knowing about `Mark`.  Includes visited marks;
    /// the caller dims them.
    func ranges(of kind: ChangeKind) -> [NSRange] {
        marks.filter { $0.kind == kind }.map(\.range)
    }

    // MARK: - Fading

    /// Identity used to carry review progress across a re-diff.  Two marks are
    /// "the same change" when they describe the same kind of edit over the same
    /// bytes; the hunk list is rebuilt from scratch on every write, so nothing
    /// else about them is stable.
    private struct MarkIdentity: Hashable {
        let kind: String
        let location: Int
        let length: Int

        init(_ mark: Mark) {
            kind = mark.kind.rawValue
            location = mark.range.location
            length = mark.range.length
        }
    }

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
