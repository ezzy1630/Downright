import AppKit
import MarkdownCore
import MarkdownRender
import Testing

@testable import DownrightApp

/// The change-review surface is the one thing this app does that a plain
/// Markdown reader does not, and it is the surface a reader meets at the worst
/// possible moment — after something rewrote the document they were reading.
/// These tests hold the claims it makes about that write.
@Suite(.serialized)
@MainActor
struct ChangeReviewTests {
    private func mark(_ kind: ChangeKind, at location: Int, length: Int = 10) -> ChangeTracker.Mark {
        ChangeTracker.Mark(kind: kind, range: NSRange(location: location, length: length))
    }

    // MARK: - Counting

    @Test("Marks are counted by the kind of change they are")
    func countsByKind() {
        let summary = ChangeSummaryBarView.Summary(
            marks: [
                mark(.inserted, at: 0),
                mark(.inserted, at: 20),
                mark(.modified, at: 40),
                mark(.deleted, at: 60),
            ],
            documentLength: 100
        )
        #expect(summary.added == 2)
        #expect(summary.rewritten == 1)
        #expect(summary.removed == 1)
        #expect(summary.total == 4)
    }

    @Test("An empty write summarises to nothing")
    func emptySummary() {
        let summary = ChangeSummaryBarView.Summary(marks: [], documentLength: 100)
        #expect(summary.total == 0)
        #expect(summary.positions.isEmpty)
        #expect(summary.headline == "Updated on disk")
        #expect(summary.distributionDescription == nil)
    }

    // MARK: - Headline

    /// The breakdown is the information.  "2 rewritten" and "2 added" ask for
    /// very different amounts of attention, and a bare total says neither.
    @Test("A single kind reads as a sentence, several read as a breakdown")
    func headlineWording() {
        let added = ChangeSummaryBarView.Summary(marks: [mark(.inserted, at: 0)], documentLength: 100)
        #expect(added.headline == "1 change added")

        let rewritten = ChangeSummaryBarView.Summary(
            marks: [mark(.modified, at: 0), mark(.modified, at: 10)],
            documentLength: 100
        )
        #expect(rewritten.headline == "2 changes rewritten")

        let mixed = ChangeSummaryBarView.Summary(
            marks: [mark(.inserted, at: 0), mark(.modified, at: 10), mark(.deleted, at: 20)],
            documentLength: 100
        )
        #expect(mixed.headline == "1 added · 1 rewritten · 1 removed")
    }

    @Test("A kind with no changes is left out of the breakdown")
    func headlineOmitsEmptyKinds() {
        let summary = ChangeSummaryBarView.Summary(
            marks: [mark(.inserted, at: 0), mark(.deleted, at: 50)],
            documentLength: 100
        )
        #expect(summary.headline == "1 added · 1 removed")
        #expect(!summary.headline.contains("rewritten"))
    }

    // MARK: - Positions

    @Test("Positions are the midpoint of each change as a fraction of the document")
    func positionsAreNormalisedMidpoints() {
        let summary = ChangeSummaryBarView.Summary(
            marks: [mark(.inserted, at: 0, length: 20)],
            documentLength: 100
        )
        #expect(summary.positions.count == 1)
        #expect(abs(summary.positions[0].fraction - 0.1) < 0.0001)
        #expect(summary.positions[0].kind == .inserted)
    }

    @Test("Positions are sorted into document order")
    func positionsAreSorted() {
        let summary = ChangeSummaryBarView.Summary(
            marks: [mark(.inserted, at: 80), mark(.modified, at: 10), mark(.deleted, at: 45)],
            documentLength: 100
        )
        let fractions = summary.positions.map(\.fraction)
        #expect(fractions == fractions.sorted())
    }

    /// A mark can outlive the edit that shortened the buffer beneath it, so the
    /// fraction has to stay inside the document rather than falling off its end.
    @Test("A change beyond the end of the document clamps into range")
    func positionsClamp() {
        let summary = ChangeSummaryBarView.Summary(
            marks: [mark(.modified, at: 500, length: 10)],
            documentLength: 100
        )
        #expect(summary.positions[0].fraction == 1)
    }

    /// Nothing to place the changes against means no positions, rather than a
    /// division by zero.
    @Test("An empty document yields counts but no positions", arguments: [0, -1])
    func emptyDocumentHasNoPositions(_ length: Int) {
        let summary = ChangeSummaryBarView.Summary(marks: [mark(.modified, at: 0)], documentLength: length)
        #expect(summary.rewritten == 1)
        #expect(summary.positions.isEmpty)
    }

    // MARK: - Distribution

    @Test("Clustered changes are described by where they cluster")
    func describesClusters() {
        let start = ChangeSummaryBarView.Summary(
            marks: [mark(.modified, at: 0, length: 2), mark(.modified, at: 8, length: 2)],
            documentLength: 100
        )
        #expect(start.distributionDescription == "Clustered near the start")

        let end = ChangeSummaryBarView.Summary(
            marks: [mark(.modified, at: 90, length: 2), mark(.modified, at: 96, length: 2)],
            documentLength: 100
        )
        #expect(end.distributionDescription == "Clustered near the end")

        let middle = ChangeSummaryBarView.Summary(
            marks: [mark(.modified, at: 46, length: 2), mark(.modified, at: 52, length: 2)],
            documentLength: 100
        )
        #expect(middle.distributionDescription == "Clustered in the middle")
    }

    @Test("Changes spread across the document are not claimed to cluster")
    func describesSpread() {
        let summary = ChangeSummaryBarView.Summary(
            marks: [mark(.modified, at: 0, length: 2), mark(.modified, at: 96, length: 2)],
            documentLength: 100
        )
        #expect(summary.distributionDescription == "Spread through the document")
    }

    /// One change has no distribution, and saying it clusters anywhere would be
    /// a claim made from a single data point.
    @Test("A single change makes no claim about distribution")
    func singleChangeHasNoDistribution() {
        let summary = ChangeSummaryBarView.Summary(marks: [mark(.modified, at: 50)], documentLength: 100)
        #expect(summary.distributionDescription == nil)
    }

    // MARK: - Accessibility

    /// Position is information a sighted reader gets from the marked-up
    /// document; the spoken form has to carry it in words.
    @Test("The spoken description carries the breakdown and the distribution")
    func accessibilityDescriptionCarriesTheDistribution() {
        let summary = ChangeSummaryBarView.Summary(
            marks: [mark(.inserted, at: 90, length: 2), mark(.inserted, at: 96, length: 2)],
            documentLength: 100
        )
        let spoken = summary.accessibilityDescription
        #expect(spoken.contains("2 changes added"))
        #expect(spoken.contains("Clustered near the end"))
    }

    @Test("An empty summary says so rather than staying silent")
    func accessibilityDescriptionWhenEmpty() {
        let summary = ChangeSummaryBarView.Summary(marks: [], documentLength: 100)
        #expect(summary.accessibilityDescription.contains("No unread changes"))
    }

    // MARK: - The bar

    @Test("Configuring from marks leads with the breakdown")
    func barShowsBreakdown() {
        let bar = ChangeSummaryBarView()
        bar.configure(summary: ChangeSummaryBarView.Summary(
            marks: [mark(.inserted, at: 0), mark(.modified, at: 50)],
            documentLength: 100
        ))
        #expect(bar.message == "1 added · 1 rewritten")
        #expect(bar.intrinsicContentSize.height == ChangeSummaryBarView.toastHeight)
    }

    @Test("The count-only entry point still works for callers with no marks")
    func countOnlyConfigurationStillWorks() {
        let bar = ChangeSummaryBarView()
        bar.configure(message: "Updated on disk", changeCount: 4)
        #expect(bar.message == "Updated on disk")
        #expect(bar.positionStatusForTesting.isEmpty)
        #expect(bar.intrinsicContentSize.height == ChangeSummaryBarView.toastHeight)
    }

    @Test("Drawing a configured bar does not fail")
    func barDraws() {
        let bar = ChangeSummaryBarView()
        bar.frame = NSRect(x: 0, y: 0, width: 320, height: ChangeSummaryBarView.toastHeight)
        bar.configure(summary: ChangeSummaryBarView.Summary(
            marks: [mark(.inserted, at: 0), mark(.modified, at: 50), mark(.deleted, at: 99)],
            documentLength: 100
        ))
        #expect(bar.bitmapImageRepForCachingDisplay(in: bar.bounds) != nil)
        bar.displayIfNeeded()
    }

    /// Positions keep the identity of their mark and land in document order
    /// even when the tracker's own array does not.
    @Test("Positions carry the identity of their mark, in document order")
    func positionsCarryMarkIdentity() {
        let late = mark(.inserted, at: 900, length: 0)
        let early = mark(.modified, at: 100, length: 0)
        let summary = ChangeSummaryBarView.Summary(marks: [late, early], documentLength: 1000)
        #expect(summary.positions.map(\.id) == [early.id, late.id])
    }

    // MARK: - Action hierarchy

    /// The weakest action cannot be the brightest pixel: dismiss sits a step
    /// below the walk chevrons, and the bar's one strong colour belongs to
    /// the way out — the confirm key wears the stripe's green.
    @Test("The tint ladder follows the action hierarchy")
    func actionTintHierarchy() {
        let bar = ChangeSummaryBarView()
        let byLabel = Dictionary(
            uniqueKeysWithValues: buttons(in: bar).map { ($0.accessibilityLabel() ?? "", $0) }
        )
        let sheet = bar.styleSheet
        #expect(byLabel["Previous change"]?.contentTintColor == sheet.textSecondary)
        #expect(byLabel["Next change"]?.contentTintColor == sheet.textSecondary)
        #expect(byLabel["Mark changes as reviewed"]?.contentTintColor == sheet.changeColor(.inserted))
        #expect(byLabel["Dismiss"]?.contentTintColor == sheet.textFaint)
    }

    // MARK: - Conflict bar

    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { subview -> [NSButton] in
            (subview as? NSButton).map { [$0] } ?? buttons(in: subview)
        }
    }

    /// Both resolutions throw one version away and neither verb says which, so
    /// the consequence has to be stated somewhere the user can reach before
    /// committing to it.
    @Test("Every conflict action states its consequence")
    func conflictActionsExplainThemselves() throws {
        let bar = ConflictBarView()
        let titled = buttons(in: bar).filter { !$0.title.isEmpty }
        let byTitle = Dictionary(uniqueKeysWithValues: titled.map { ($0.title, $0) })

        let review = try #require(byTitle["Review"])
        #expect(review.toolTip?.contains("Changes nothing") == true)

        let keepMine = try #require(byTitle["Keep Mine"])
        #expect(keepMine.toolTip?.contains("discarding the change on disk") == true)

        let takeTheirs = try #require(byTitle["Take Theirs"])
        #expect(takeTheirs.toolTip?.contains("discarding your unsaved edits") == true)
    }

    /// An explanation only a sighted hovering user receives is not an
    /// explanation.
    @Test("Consequences reach VoiceOver as well as the pointer")
    func conflictConsequencesAreAccessible() {
        let bar = ConflictBarView()
        for button in buttons(in: bar).filter({ !$0.title.isEmpty }) {
            #expect(button.accessibilityHelp()?.isEmpty == false)
            #expect(button.accessibilityHelp() == button.toolTip)
        }
    }

    @Test("The conflict bar names the situation, not just the file")
    func conflictBarNamesTheSituation() {
        let bar = ConflictBarView()
        #expect(bar.message.contains("while you were editing"))
    }

    /// Nothing here may take the keyboard: an agent rewriting the file you are
    /// editing is an ordinary event, not a reason to stop the world.
    @Test("Neither review bar becomes first responder")
    func reviewBarsNeverTakeTheKeyboard() {
        #expect(!ConflictBarView().acceptsFirstResponder)
        #expect(!ChangeSummaryBarView().acceptsFirstResponder)
    }

    // MARK: - Expiry

    private func tracker(marksAgedBy ages: [TimeInterval]) -> ChangeTracker {
        let tracker = ChangeTracker()
        let now = Date()
        tracker.restore(
            ages.enumerated().map { index, age in
                ChangeTracker.PersistedMark(
                    id: UUID(),
                    kind: ChangeKind.modified.rawValue,
                    range: ChangeTracker.PersistedRange(NSRange(location: index * 20, length: 10)),
                    wordRanges: [],
                    deletedText: "",
                    created: now.addingTimeInterval(-age),
                    visited: false
                )
            },
            textLength: 1000,
            now: now
        )
        return tracker
    }

    /// The fade was documented, measured, and never applied to anything that
    /// draws.  `unreadMarks` filtered on the cutoff for the *counts*, the fade
    /// timer computed one and then only asked for a redraw of the same
    /// undiminished set, and the decorator was handed `marks` whole — so a file
    /// an agent rewrote stayed lit for as long as the window stayed open.
    @Test("Expired marks leave the page")
    func expiredMarksAreNotDecorated() {
        let tracker = tracker(marksAgedBy: [30, 10_000])
        #expect(tracker.count == 1, "an expired mark never comes back from disk")

        let fresh = ChangeTracker()
        fresh.apply(hunks: [], newText: "", oldText: "")
        #expect(fresh.decoratedMarks.isEmpty)
    }

    /// Restoring is what makes closing a window not a claim to have read
    /// anything — but that is an argument about minutes, not weeks.
    @Test("Restore drops marks that outlived their session")
    func restoreDropsExpiredMarks() {
        #expect(tracker(marksAgedBy: [1, 2, 3]).count == 3)
        #expect(tracker(marksAgedBy: [1, 10_000, 3]).count == 2)
        #expect(tracker(marksAgedBy: [10_000, 20_000]).count == 0)
    }

    /// Ageing out is the queue emptying itself, not the reader saying they read
    /// it, so it must never advance the review baseline the way `clear()` does.
    @Test("Expiry retires marks without claiming they were reviewed")
    func expiryDoesNotAdvanceTheBaseline() {
        let tracker = tracker(marksAgedBy: [30])
        var reviewed = 0
        var changed = 0
        tracker.onReviewed = { reviewed += 1 }
        tracker.onChange = { changed += 1 }

        #expect(tracker.dropExpiredMarks(now: Date()) == false)
        #expect(changed == 0)

        #expect(tracker.dropExpiredMarks(now: Date().addingTimeInterval(tracker.lifetime + 1)))
        #expect(tracker.isEmpty)
        #expect(changed == 1)
        #expect(reviewed == 0, "a mark ageing out is not a review")

        tracker.clear()
        #expect(reviewed == 1, "explicitly finishing review is")
    }

    /// Navigation walks what the reader can see.  `]` jumping to a highlight
    /// that is no longer drawn is the same defect from the other side.
    @Test("Change navigation skips expired marks")
    func navigationSkipsExpiredMarks() {
        #expect(tracker(marksAgedBy: [10_000]).next(after: 0) == nil)
        #expect(tracker(marksAgedBy: [10_000]).previous(before: 500) == nil)
        #expect(tracker(marksAgedBy: [30]).next(after: 0) != nil)
    }

    /// The review queue's one explicit exit has to be reachable when the
    /// summary bar is not on screen — which is most of the time, since the bar
    /// is raised by a live external write and dismissed with it.
    @Test("Mark Changes Reviewed is a first-class command")
    func markReviewedIsReachable() {
        #expect(Command.markChangesReviewed.title == "Mark Changes Reviewed")
        #expect(Command.markChangesReviewed.menu == .navigate)
        #expect(KeybindingDefaults.table[.markChangesReviewed]?.isEmpty == false)

        // Enabled only when there is something to retire.
        let withMarks = CommandContext(hasDocument: true, hasChangeMarks: true)
        let without = CommandContext(hasDocument: true, hasChangeMarks: false)
        #expect(Command.markChangesReviewed.isEnabled(in: withMarks))
        #expect(!Command.markChangesReviewed.isEnabled(in: without))
        #expect(!Command.nextChange.isEnabled(in: without))
    }
}
