import AppKit
import MarkdownCore
import Testing
@testable import DownrightApp

@MainActor
@Suite(.serialized)
struct PanelAccessibilityTests {
    private func makeTask(
        _ text: String, checked: Bool, at location: Int, headingIndex: Int? = nil, indent: Int = 0
    ) -> TaskItem {
        TaskItem(
            isChecked: checked,
            markRange: NSRange(location: location + 3, length: 1),
            contentRange: NSRange(location: location, length: 12),
            text: text,
            headingIndex: headingIndex,
            indentLevel: indent
        )
    }

    @Test
    func taskPanelSummarisesAFinishedPlan() {
        let view = TaskPanelView()
        view.tasks = [makeTask("Done", checked: true, at: 0)]

        #expect((view.accessibilityValue() as? String) == "1 task done")
        #expect(view.statusLineForTesting == "1 task done")
        #expect(view.captionForTesting == "1 task done")
        // A section with nothing left lists its finished work instead of
        // piling it.  The pile keeps completed tasks from becoming a wall of
        // check marks *above the work that remains*; with no work remaining
        // there is no wall to hold back, and hiding the section's only
        // contents left the panel looking empty beside a document showing all
        // of them.
        #expect(view.visibleTaskCountForTesting == 1)
        #expect(view.pileRowCountForTesting == 0, "a finished section should not pile")
    }

    /// The pile still does its job where it earns it: a section that has both
    /// finished and unfinished work leads with what is left.
    @Test
    func taskPanelPilesCompletedWorkWhileWorkRemains() {
        let view = TaskPanelView()
        view.tasks = [
            makeTask("Done", checked: true, at: 0),
            makeTask("Open", checked: false, at: 13),
        ]

        #expect(view.pileRowCountForTesting == 1, "a mixed section should pile its done work")
        #expect(view.visibleTaskCountForTesting == 1, "only the open task lists")

        view.setCompletedPileExpandedForTesting(true, section: 0)
        #expect(view.visibleTaskCountForTesting == 2)
    }

    @Test
    func taskPanelListsOpenWorkFirstWithoutLosingProgress() {
        let view = TaskPanelView()
        view.tasks = [
            makeTask("Done", checked: true, at: 0),
            makeTask("Open", checked: false, at: 13),
        ]

        #expect(view.progress == (done: 1, total: 2))
        #expect(view.preferredWidth == 300)
        #expect(view.statusLineForTesting == "1 of 2 done · next: Open")
        #expect(view.captionForTesting == "1 of 2 done")
        // Open work lists; the finished task waits in the collapsed pile.
        #expect(view.visibleTaskCountForTesting == 1)

        view.setCompletedPileExpandedForTesting(true, section: 0)
        #expect(view.visibleTaskCountForTesting == 2)
        #expect(view.progress == (done: 1, total: 2))
    }

    @Test
    func taskPanelEmptyStatePointsAtQuickAdd() {
        let view = TaskPanelView()
        #expect((view.accessibilityValue() as? String) == "No tasks")
        #expect(view.visibleTaskCountForTesting == 0)
        #expect(view.captionForTesting == "")
        #expect(view.emptyAddButtonForTesting.title == "Add task")
        #expect(view.emptyAddButtonForTesting.accessibilityRole() == .button)
        view.emptyAddButtonForTesting.performClick(nil)
        #expect(view.quickAddEditingForTesting)
    }

    @Test
    func undoPillReservesTheLastRows() {
        let view = TaskPanelView()
        let baseInset = view.undoBottomInsetForTesting
        view.presentUndoForTesting(title: "Done")
        #expect(view.undoBottomInsetForTesting > baseInset)
        view.dismissUndoForTesting()
        #expect(view.undoBottomInsetForTesting == baseInset)
    }

    @Test("Undo pill exposes a named action")
    func undoPillNamesItsAction() {
        let view = TaskPanelView()
        view.presentUndoForTesting(title: "Done")

        func descendants(of parent: NSView) -> [NSView] {
            parent.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        let undo = descendants(of: view).compactMap { $0 as? NSButton }
            .first { $0.title == "Undo" }
        #expect(undo?.accessibilityLabel() == "Undo")
    }

    @Test
    func searchResultsExposeSearchingAndEmptyStates() {
        let view = SearchResultsPanelView()
        view.isSearching = true
        #expect((view.accessibilityValue() as? String) == "Searching…")
        view.isSearching = false
        #expect((view.accessibilityValue() as? String) == "No matches")
    }

    @Test
    func findAccentGlyphDoesNotDuplicateTheSearchFieldAnnouncement() {
        let bar = FindBarView()
        #expect(!bar.leadingGlyphIsAccessibleForTesting)
        #expect(bar.accessibilityRole() == .group)
    }

    @Test
    func inspectorSectionNavigationStaysInSync() {
        let host = InspectorHostView()
        host.setContent(NSView(), section: .search)
        host.setContent(NSView(), section: .tasks)

        host.select(.search)
        #expect(host.selectedSection == .search)
        #expect((host.accessibilityValue() as? String) == "Search section")
    }

    @Test("The resting close control remains available to assistive technology")
    func inspectorCloseIsAccessibleWhileVisuallyQuiet() {
        let host = InspectorHostView()
        host.setContent(NSView(), section: .tasks)

        let close = host.closeButtonForTesting
        #expect(close.alphaValue == 0)
        #expect(!close.isHidden)
        #expect(close.accessibilityRole() == .button)
        #expect(close.accessibilityLabel() == "Close inspector")
    }
}
