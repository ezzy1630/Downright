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

    // MARK: - Ribbon positions

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
    /// fraction has to stay on the track rather than drawing off the end of it.
    @Test("A change beyond the end of the document clamps into range")
    func positionsClamp() {
        let summary = ChangeSummaryBarView.Summary(
            marks: [mark(.modified, at: 500, length: 10)],
            documentLength: 100
        )
        #expect(summary.positions[0].fraction == 1)
    }

    /// Nothing to place the changes against means no ribbon, rather than a
    /// division by zero.
    @Test("An empty document yields counts but no ribbon", arguments: [0, -1])
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

    /// The ribbon is pure colour and position, so everything it shows has to be
    /// available in words as well.
    @Test("The spoken description carries the breakdown and the distribution")
    func accessibilityDescriptionCarriesTheRibbon() {
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
        #expect(bar.intrinsicContentSize.height == PanelMetrics.reviewBarHeight)
    }

    @Test("The count-only entry point still works for callers with no marks")
    func countOnlyConfigurationStillWorks() {
        let bar = ChangeSummaryBarView()
        bar.configure(message: "Updated on disk", changeCount: 4)
        #expect(bar.message == "Updated on disk")
        #expect(bar.positionStatusForTesting.isEmpty)
        #expect(bar.intrinsicContentSize.height == PanelMetrics.reviewBarHeight)
    }

    @Test("Drawing a summary with a ribbon does not fail")
    func barDrawsRibbon() {
        let bar = ChangeSummaryBarView()
        bar.frame = NSRect(x: 0, y: 0, width: 320, height: PanelMetrics.reviewBarHeight)
        bar.configure(summary: ChangeSummaryBarView.Summary(
            marks: [mark(.inserted, at: 0), mark(.modified, at: 50), mark(.deleted, at: 99)],
            documentLength: 100
        ))
        #expect(bar.bitmapImageRepForCachingDisplay(in: bar.bounds) != nil)
        bar.displayIfNeeded()
    }

    // MARK: - Ribbon interaction

    /// 380pt wide, so the track runs from x=12.5 to x=367.5 and the extremes sit
    /// at midX 13.75 and 366.25.
    private func ribbonBar(_ marks: [ChangeTracker.Mark], documentLength: Int = 1000) -> ChangeSummaryBarView {
        let bar = ChangeSummaryBarView()
        bar.frame = NSRect(x: 0, y: 0, width: 380, height: PanelMetrics.reviewBarHeight)
        bar.configure(summary: ChangeSummaryBarView.Summary(marks: marks, documentLength: documentLength))
        return bar
    }

    @Test("A click near a tick selects that change")
    func clickSelectsNearestChange() throws {
        let first = mark(.inserted, at: 0, length: 0)
        let last = mark(.deleted, at: 1000, length: 0)
        let bar = ribbonBar([first, last])

        let atStart = try #require(bar.change(at: NSPoint(x: 13.75, y: 5)))
        #expect(atStart.id == first.id)

        let atEnd = try #require(bar.change(at: NSPoint(x: 366.25, y: 5)))
        #expect(atEnd.id == last.id)
    }

    @Test("A click slightly off a tick still selects it")
    func clickToleratesImprecision() throws {
        let only = mark(.modified, at: 500, length: 0)
        let bar = ribbonBar([only])
        for offset in [-6.0, -3.0, 0.0, 3.0, 6.0] {
            let hit = try #require(bar.change(at: NSPoint(x: 190 + offset, y: 5)))
            #expect(hit.id == only.id)
        }
    }

    /// Clicking bare track must do nothing.  Snapping to the nearest change from
    /// anywhere on the ribbon would send a reader somewhere they did not point.
    @Test("A click on empty track selects nothing")
    func clickOnEmptyTrackDoesNothing() {
        let bar = ribbonBar([mark(.modified, at: 0, length: 0), mark(.modified, at: 1000, length: 0)])
        #expect(bar.change(at: NSPoint(x: 190, y: 5)) == nil)
    }

    /// The band provides a 24pt target from the bottom; the label and actions
    /// above it keep their own clicks.
    @Test("A click above the ribbon band is not a ribbon click")
    func clickAboveBandIsIgnored() {
        let bar = ribbonBar([mark(.modified, at: 500, length: 0)])
        #expect(bar.change(at: NSPoint(x: 190, y: 5)) != nil)
        #expect(bar.change(at: NSPoint(x: 190, y: 25)) == nil)
    }

    @Test("A bar with no changes has no ribbon to click")
    func emptyBarHasNoRibbon() {
        let bar = ribbonBar([])
        #expect(bar.change(at: NSPoint(x: 190, y: 5)) == nil)
        #expect(bar.change(at: NSPoint(x: 13.75, y: 5)) == nil)
    }

    /// The tick has to name a mark, not an ordinal: the ribbon is sorted by
    /// position and the tracker's array is not, so an index would address the
    /// wrong change the moment those orders disagreed.
    @Test("Ticks carry the identity of their mark, in document order")
    func ticksCarryMarkIdentity() {
        let late = mark(.inserted, at: 900, length: 0)
        let early = mark(.modified, at: 100, length: 0)
        let summary = ChangeSummaryBarView.Summary(marks: [late, early], documentLength: 1000)
        #expect(summary.positions.map(\.id) == [early.id, late.id])
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
}
