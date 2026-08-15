import AppKit
import MarkdownCore
import Testing
@testable import DownrightApp

@MainActor
@Suite(.serialized)
struct PanelAccessibilityTests {
    private final class TaskDelegateSpy: TaskPanelDelegate {
        var additions: [(text: String, headingIndex: Int?)] = []

        func taskPanel(_ panel: TaskPanelView, didToggleTaskAt markOffset: Int) {}
        func taskPanel(_ panel: TaskPanelView, didSelectTaskAt contentOffset: Int) {}
        func taskPanel(
            _ panel: TaskPanelView, didRequestNewTask text: String, headingIndex: Int?
        ) {
            additions.append((text, headingIndex))
        }
        func taskPanel(
            _ panel: TaskPanelView, didMoveTask taskIndex: Int, before targetIndex: Int?
        ) {}
    }

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

    @Test("The task checkbox hit target stays centred on its drawn circle")
    func taskCheckboxHitTargetUsesLocalCoordinates() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 44))
        let checkbox = PanelCheckbox(side: 17, cornerRatio: 0.5)
        checkbox.frame.origin = NSPoint(x: 48, y: 13)
        parent.addSubview(checkbox)

        // `hitTest` receives its point in the receiver's *superview* space
        // (AppKit feeds the chain unconverted), so every probe is expressed
        // in the parent's coordinates.
        let centre = NSPoint(x: 48 + 8.5, y: 13 + 8.5)
        #expect(checkbox.hitTest(centre) === checkbox)
        // The 6pt slack around the drawn box still belongs to it.
        #expect(checkbox.hitTest(NSPoint(x: 48 - 5, y: 13 + 8.5)) === checkbox)
        // Beyond the slack the box must not claim hits.
        #expect(checkbox.hitTest(NSPoint(x: 48 - 7, y: 13 + 8.5)) == nil)
        // Nothing outside the parent's bounds routes to the box.
        #expect(checkbox.hitTest(NSPoint(x: 179, y: 8.5)) == nil)
    }

    @Test("Narrow task panels remeasure wrapped labels at their real width")
    func narrowTaskPanelMeasuresWrappedRowsAtLiveWidth() {
        let view = TaskPanelView()
        view.tasks = [makeTask(
            "A long task label that must wrap when the floating card is narrowed",
            checked: false,
            at: 0
        )]

        view.frame = NSRect(x: 0, y: 0, width: 220, height: 320)
        view.layoutSubtreeIfNeeded()
        let narrow = view.measuredListHeightForTesting

        view.frame.size.width = 300
        view.layoutSubtreeIfNeeded()
        let wide = view.measuredListHeightForTesting

        #expect(narrow > wide)
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
        let delegate = TaskDelegateSpy()
        view.delegate = delegate
        #expect((view.accessibilityValue() as? String) == "No tasks")
        #expect(view.visibleTaskCountForTesting == 0)
        #expect(view.captionForTesting == "")
        #expect(view.emptyAddButtonForTesting.title == "Add Markdown task")
        #expect(view.emptyAddButtonForTesting.toolTip == "Insert a - [ ] checkbox into this document")
        #expect(view.emptyAddButtonForTesting.accessibilityRole() == .button)
        view.emptyAddButtonForTesting.performClick(nil)
        #expect(view.quickAddEditingForTesting)
        view.commitNewTaskForTesting("Ship the polished panel")
        #expect(delegate.additions.count == 1)
        #expect(delegate.additions.first?.text == "Ship the polished panel")
        #expect(delegate.additions.first?.headingIndex == nil)
    }

    @Test("The populated Add task row responds to accessibility press")
    func taskPanelAddRowSupportsEveryPressPath() {
        let view = TaskPanelView()
        view.tasks = [makeTask("Open", checked: false, at: 0)]
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 320)
        view.layoutSubtreeIfNeeded()

        #expect(view.performAddRowAccessibilityPressForTesting())
        #expect(view.quickAddEditingForTesting)
    }

    @Test("The task table claims command-N before the app menu")
    func taskTableClaimsQuickAddKeyEquivalent() {
        let table = PanelTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        var claimed = false
        table.onKeyEvent = { event in
            claimed = event.keyCode == 45
            return claimed
        }
        let event = try? #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "n",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 45
        ))
        #expect(event != nil)
        #expect(table.performKeyEquivalent(with: event!))
        #expect(claimed)
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

    @Test("The resting close control is visible, accessible, and clickable")
    func inspectorCloseIsAlwaysAvailable() {
        let host = InspectorHostView()
        var closeCount = 0
        host.onClose = { closeCount += 1 }
        host.setContent(NSView(), section: .tasks)
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 240)
        host.layoutSubtreeIfNeeded()

        let close = host.closeButtonForTesting
        #expect(close.alphaValue == 1)
        #expect(!close.isHidden)
        #expect(close.accessibilityRole() == .button)
        #expect(close.accessibilityLabel() == "Close inspector")

        let closePoint = host.convert(
            NSPoint(x: close.bounds.midX, y: close.bounds.midY), from: close
        )
        #expect(host.hitTest(closePoint) === close)
        close.performClick(nil)
        #expect(closeCount == 1)
        #expect(close.accessibilityPerformPress())
        #expect(closeCount == 2)
    }
}
