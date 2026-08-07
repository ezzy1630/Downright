import Foundation
import Testing
import MarkdownCore
@testable import DownrightApp

// The review baseline (§8.1, §8.2).
//
// One idea underneath all of these: change marks are *reviewable state*, and
// only the user advances it.  A file the agent rewrote five times still owes
// the reader an account of everything that moved since they last looked; a
// window that was closed has not been read; and a mark you scrolled past is
// dimmed, not deleted.
//
// Serialised because the document, snapshot, and state stores are process-wide
// singletons.

@Suite(.serialized)
struct ReviewBaselineTests {

    // MARK: - Fixtures

    private static func makeSandbox() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-baseline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static let original = """
    # Report

    Alpha paragraph.

    Bravo paragraph.

    Charlie paragraph.

    """

    /// The agent's three writes, each touching a different paragraph.  Diffed
    /// against each other they are one change apiece; diffed against the
    /// original they accumulate, which is the distinction under test.
    private static let writes = [
        original.replacingOccurrences(of: "Alpha paragraph.", with: "Alpha paragraph, revised."),
        original
            .replacingOccurrences(of: "Alpha paragraph.", with: "Alpha paragraph, revised.")
            .replacingOccurrences(of: "Bravo paragraph.", with: "Bravo paragraph, revised."),
        original
            .replacingOccurrences(of: "Alpha paragraph.", with: "Alpha paragraph, revised.")
            .replacingOccurrences(of: "Bravo paragraph.", with: "Bravo paragraph, revised.")
            .replacingOccurrences(of: "Charlie paragraph.", with: "Charlie paragraph, revised."),
    ]

    // MARK: - 1. A burst diffs against the baseline, not the previous write

    @Test @MainActor
    func burstOfWritesReportsChangesAgainstTheOriginalBaseline() throws {
        let root = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("report.md")
        try Data(Self.original.utf8).write(to: url)

        let document = MarkdownDocument()
        try document.open(url)
        defer { document.close() }

        // Absorb each write separately — the case the debounce does *not*
        // cover, and the one that used to lose writes 1 and 2.
        for write in Self.writes {
            try Data(write.utf8).write(to: url)
            document.handleExternalWrite()
            document.flushPendingExternalWrite()
        }

        #expect(document.text == Self.writes[2])
        #expect(
            document.changes.count == 3,
            """
            after three writes the reader must still see all three changes; \
            got \(document.changes.count), which means the diff was taken \
            against the previous write instead of the review baseline
            """
        )
        #expect(document.reviewBaselineText == Self.original, "an incoming write must not move the baseline")

        // Finishing the review is the only thing that moves it.
        document.markChangesReviewed()
        #expect(document.changes.isEmpty)
        #expect(document.reviewBaselineText == Self.writes[2])
        #expect(document.unreadChanges == .none)
    }

    /// The trailing quiet period folds a genuine burst into a single absorb —
    /// one buffer replace, one reparse, one scroll restore — while still
    /// reporting every change the burst made.
    @Test @MainActor
    func aDebouncedBurstAbsorbsOnceAndStillReportsEveryChange() throws {
        let root = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("report.md")
        try Data(Self.original.utf8).write(to: url)

        let document = MarkdownDocument()
        try document.open(url)
        defer { document.close() }

        var appliedEvents = 0
        document.onExternalEvent = { event in
            if case .applied = event { appliedEvents += 1 }
        }

        for write in Self.writes {
            try Data(write.utf8).write(to: url)
            document.handleExternalWrite()
        }
        document.flushPendingExternalWrite()

        #expect(appliedEvents == 1, "a burst must rebuild the document once, not once per write")
        #expect(document.text == Self.writes[2])
        #expect(document.changes.count == 3)
    }

    // MARK: - 2. Marks survive a close/reopen cycle

    @Test @MainActor
    func marksSurviveACloseAndReopenCycle() async throws {
        let root = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("report.md")
        try Data(Self.original.utf8).write(to: url)

        let first = MarkdownDocument()
        try first.open(url)
        try Data(Self.writes[2].utf8).write(to: url)
        first.handleExternalWrite()
        first.flushPendingExternalWrite()

        let markCount = first.changes.count
        #expect(markCount == 3)
        // The reader worked through exactly one of them before closing.
        let reviewed = try #require(first.changes.marks.first)
        first.changes.markVisited(reviewed.id)
        first.close()

        await SnapshotStore.shared.waitForPendingWrites()

        let second = MarkdownDocument()
        try second.open(url)
        defer { second.close() }

        #expect(
            second.changes.count == markCount,
            "closing a window is not reviewing its changes"
        )
        #expect(second.unreadChanges == .marked(count: markCount))
        #expect(
            second.changes.marks.filter(\.visited).count == 1,
            "the one mark the reader had worked through must come back dimmed, not unread"
        )
        #expect(second.changes.unreadCount == markCount - 1)
    }

    /// The degraded case: the bytes moved while the app was closed and the
    /// previous text has been pruned.  The old guard collapsed this into
    /// "nothing changed"; it has to stay separable from that.
    @Test @MainActor
    func aPrunedBaselineSurfacesADegradedStateRatherThanSilence() throws {
        let root = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("report.md")
        try Data(Self.writes[2].utf8).write(to: url)

        var state = DocumentStateStore.shared.state(for: url)
        state.reviewBaselineHash = String(repeating: "0", count: 64)  // no such object
        DocumentStateStore.shared.save(state, for: url)

        let document = MarkdownDocument()
        try document.open(url)
        defer { document.close() }

        #expect(document.unreadChanges == .previousVersionUnavailable(reason: .pruned))
        #expect(document.changes.isEmpty, "there is nothing to anchor a mark to")
    }

    /// A truncated object must not come back as text.  The store is
    /// content-addressed, so the name is the checksum and the check is exact.
    @Test
    func aCorruptObjectIsReportedAsCorruptRatherThanReturnedAsMojibake() async throws {
        let root = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("report.md")
        let store = SnapshotStore.shared
        defer { store.forget(url) }

        let record = try #require(store.record(Self.original, for: url, kind: .baseline))
        await store.waitForPendingWrites()
        #expect(store.content(forHash: record.hash) == .text(Self.original))

        let objectURL = AppPaths.historyDirectory
            .appendingPathComponent("objects", isDirectory: true)
            .appendingPathComponent(String(record.hash.prefix(2)), isDirectory: true)
            .appendingPathComponent(record.hash)
        let intact = try Data(contentsOf: objectURL)
        // The object store is content-addressed and lives in the *user's*
        // support folder, so a truncated object left behind poisons every
        // later run — `writeObjectIfNeeded` skips a hash that already exists,
        // so nothing ever heals it.  Put the bytes back before leaving.
        defer { try? intact.write(to: objectURL, options: .atomic) }
        try intact.prefix(intact.count / 2).write(to: objectURL)

        #expect(store.content(forHash: record.hash) == .corrupt)
        #expect(store.text(forHash: record.hash) == nil)
        #expect(store.content(forHash: String(repeating: "f", count: 64)) == .missing)
    }

    // MARK: - 3. Visiting dims a mark; it does not remove it

    @Test
    func visitingAMarkDimsItRatherThanRemovingIt() throws {
        let tracker = ChangeTracker()
        tracker.apply(hunks: [
            ChangeHunk(kind: .inserted,
                       newRange: NSRange(location: 0, length: 5),
                       oldRange: NSRange(location: 0, length: 0)),
        ])
        let mark = try #require(tracker.marks.first)

        tracker.markVisited(mark.id)
        #expect(tracker.marks.count == 1, "a visited mark stays drawable so the reader can find it again")
        #expect(tracker.marks[0].visited, "…dimmed")
        #expect(tracker.unreadMarks.isEmpty, "…but no longer counted as unread")
        #expect(tracker.next(after: 0)?.id == mark.id, "…and still navigable")
    }

    /// Arriving at a change is not reviewing it; moving on from one is.
    @Test
    func aMarkIsVisitedOnDepartureNotOnArrival() throws {
        let tracker = ChangeTracker()
        tracker.dwell = 1.5
        tracker.apply(hunks: [
            ChangeHunk(kind: .modified,
                       newRange: NSRange(location: 100, length: 20),
                       oldRange: NSRange(location: 100, length: 20)),
        ])
        let start = Date()

        tracker.noteVisibleRange(NSRange(location: 80, length: 120), now: start)
        #expect(tracker.marks[0].visited == false, "arriving at a change must not dim it")

        tracker.noteVisibleRange(NSRange(location: 80, length: 120), now: start.addingTimeInterval(0.2))
        #expect(tracker.marks[0].visited == false, "a glance is not a read")

        tracker.noteVisibleRange(NSRange(location: 400, length: 120), now: start.addingTimeInterval(0.4))
        #expect(tracker.marks[0].visited, "scrolling past it counts as having seen it")
        #expect(tracker.marks.count == 1)
    }

    @Test
    func dwellingOnAMarkVisitsItWithoutScrollingAway() {
        let tracker = ChangeTracker()
        tracker.dwell = 1.0
        tracker.apply(hunks: [
            ChangeHunk(kind: .modified,
                       newRange: NSRange(location: 10, length: 5),
                       oldRange: NSRange(location: 10, length: 5)),
        ])
        let start = Date()
        tracker.noteVisibleRange(NSRange(location: 0, length: 200), now: start)
        #expect(tracker.marks[0].visited == false)
        tracker.noteVisibleRange(NSRange(location: 0, length: 200), now: start.addingTimeInterval(1.2))
        #expect(tracker.marks[0].visited)
    }

    // MARK: - 4. Deletions are locatable

    @Test
    func deletionsProduceAHunkTheUICanLocate() throws {
        let old = "Keep this.\nDelete this whole line.\nKeep this too.\n"
        let new = "Keep this.\nKeep this too.\n"
        let hunks = TextDiff.hunks(old: old, new: new)
        let hunk = try #require(hunks.first)
        #expect(hunk.kind == .deleted)
        #expect((old as NSString).substring(with: hunk.oldRange) == "Delete this whole line.\n")

        // The hunk's own new-text range is empty by definition; the anchor the
        // UI draws must not be.
        #expect(hunk.newRange.length == 0)
        let anchor = TextDiff.anchorRange(for: hunk, inNewTextOfLength: (new as NSString).length)
        #expect(anchor.length > 0, "a zero-length range is clamped away by the overlay")
        #expect(anchor.upperBound <= (new as NSString).length)

        // …and the tracker hands the render layer both halves: where the text
        // used to be, and what it said.
        let tracker = ChangeTracker()
        tracker.apply(hunks: hunks, newText: new, oldText: old)
        let mark = try #require(tracker.marks.first)
        #expect(mark.kind == .deleted)
        #expect(mark.range.length > 0)
        #expect(mark.range.upperBound <= (new as NSString).length)
        #expect(mark.deletedText == "Delete this whole line.\n", "the ghost block needs the removed bytes")
    }

    @Test
    func aDeletionAtTheEndOfTheDocumentStillAnchors() throws {
        let old = "Alpha.\nOmega.\n"
        let new = "Alpha.\n"
        let hunks = TextDiff.hunks(old: old, new: new)
        let hunk = try #require(hunks.first)
        #expect(hunk.kind == .deleted)
        let anchor = TextDiff.anchorRange(for: hunk, inNewTextOfLength: (new as NSString).length)
        #expect(anchor.length == 1)
        #expect(anchor.upperBound <= (new as NSString).length, "the anchor must stay inside the buffer")
    }

    // MARK: - 5. Insertions carry word ranges

    @Test
    func insertionsCarryWordRanges() throws {
        let old = "Opening line.\nClosing line.\n"
        let new = "Opening line.\nA brand new paragraph the agent added.\nClosing line.\n"
        let hunks = TextDiff.hunks(old: old, new: new)
        let hunk = try #require(hunks.first)
        #expect(hunk.kind == .inserted)
        #expect(
            !hunk.wordRanges.isEmpty,
            "new prose got a hairline while merely modified text got a full highlight — the signal was inverted"
        )

        let ns = new as NSString
        for range in hunk.wordRanges {
            #expect(range.location >= hunk.newRange.location)
            #expect(range.upperBound <= hunk.newRange.upperBound)
        }
        let highlighted = hunk.wordRanges.map { ns.substring(with: $0) }.joined(separator: " ")
        #expect(highlighted.contains("brand new paragraph"))
        #expect(
            !highlighted.contains("\n"),
            "a background painted over a line terminator draws a full-width block"
        )

        let tracker = ChangeTracker()
        tracker.apply(hunks: hunks, newText: new, oldText: old)
        #expect(tracker.marks.first?.wordRanges.isEmpty == false)
    }

    // MARK: - Persistence round trip

    @Test
    func persistedMarksRoundTripThroughDocumentState() throws {
        let tracker = ChangeTracker()
        tracker.apply(
            hunks: TextDiff.hunks(old: "a\ngone\nb\n", new: "a\nb\nnew\n"),
            newText: "a\nb\nnew\n",
            oldText: "a\ngone\nb\n"
        )
        #expect(!tracker.marks.isEmpty)
        tracker.markVisited(tracker.marks[0].id)

        var state = DocumentState(path: "/tmp/note.md")
        state.marks = tracker.persistedMarks
        state.reviewBaselineHash = "abc123"

        let encoded = try JSONEncoder.snapshotEncoder.encode(state)
        let decoded = try JSONDecoder.snapshotDecoder.decode(DocumentState.self, from: encoded)
        #expect(decoded.reviewBaselineHash == "abc123")
        // The state file dates are ISO 8601 to the second, so `created` is
        // deliberately lossy and whole-value equality can only pass by luck.
        // What has to survive is the reader's progress and the anchors.
        #expect(decoded.marks.map(\.id) == state.marks.map(\.id))
        #expect(decoded.marks.map(\.kind) == state.marks.map(\.kind))
        #expect(decoded.marks.map(\.range) == state.marks.map(\.range))
        #expect(decoded.marks.map(\.wordRanges) == state.marks.map(\.wordRanges))
        #expect(decoded.marks.map(\.deletedText) == state.marks.map(\.deletedText))
        #expect(decoded.marks.map(\.visited) == state.marks.map(\.visited))
        for (decodedMark, original) in zip(decoded.marks, state.marks) {
            #expect(abs(decodedMark.created.timeIntervalSince(original.created)) < 1)
        }

        let restored = ChangeTracker()
        restored.restore(decoded.marks, textLength: ("a\nb\nnew\n" as NSString).length)
        #expect(restored.marks.count == tracker.marks.count)
        #expect(restored.marks[0].visited)
        #expect(restored.marks[0].deletedText == tracker.marks[0].deletedText)
    }

    /// A state file written before the baseline existed must not re-mark the
    /// whole document on first launch after the upgrade.
    @Test
    func legacyStateFallsBackToTheDiskHashAsItsBaseline() throws {
        let legacy = """
        {"path":"/tmp/note.md","lastSeenHash":"deadbeef","anchor":\
        {"headingSlug":"","headingIndex":0,"fractionThroughSection":0},\
        "mode":"live","zoomLevel":5,"foldedHeadings":[],\
        "expandedCodeBlocks":[],"collapsedCodeBlocks":[],\
        "lastOpened":"2024-01-01T00:00:00Z","sidebarVisible":false,\
        "selectionLocation":0,"selectionLength":0,"splitViewEnabled":false}
        """
        let decoded = try JSONDecoder.snapshotDecoder.decode(
            DocumentState.self, from: Data(legacy.utf8)
        )
        #expect(decoded.reviewBaselineHash == "deadbeef")
        #expect(decoded.marks.isEmpty)
    }

    // MARK: - Undoing an external change is surfaced, not silent

    @Test @MainActor
    func undoingAnExternalChangeSurfacesAConflict() throws {
        let root = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("report.md")
        try Data(Self.original.utf8).write(to: url)

        let document = MarkdownDocument()
        try document.open(url)
        defer { document.close() }

        var conflicts = 0
        document.onExternalEvent = { event in
            if case .conflict = event { conflicts += 1 }
        }

        try Data(Self.writes[2].utf8).write(to: url)
        document.handleExternalWrite()
        document.flushPendingExternalWrite()
        #expect(document.text == Self.writes[2])
        #expect(document.isDirty == false)

        document.undoManager.undo()

        #expect(document.text == Self.original, "⌘Z must put the agent's rewrite back")
        #expect(document.isDirty, "the buffer now disagrees with the file on disk")
        #expect(conflicts == 1, "and that disagreement has to be visible, not discovered at save time")
        #expect(document.pendingConflict != nil)

        // The save that would have failed for no visible reason is now refused
        // with the conflict already on screen.
        #expect(throws: SaveError.self) { try document.save() }
    }
}
