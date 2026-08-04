import AppKit
import MarkdownCore
import Testing
@testable import DownrightApp

@MainActor
@Suite(.serialized)
struct PanelAccessibilityTests {
    @Test
    func outlineSearchIncludesMatchesInsideFoldedSections() {
        let view = OutlinePanelView()
        view.headings = MarkdownParser.parse("# Project\n\n## Notes\n\n### Deep work\n").headings
        view.foldedIndices = [0]
        view.filterText = "Deep"

        #expect(view.filterMatchCountForTesting == 1)
        #expect(view.visibleRowCountForTesting == 3)
    }

    @Test
    func taskFilterExplainsEmptyResult() {
        let view = TaskPanelView()
        view.tasks = [TaskItem(
            isChecked: true,
            markRange: NSRange(location: 3, length: 1),
            contentRange: NSRange(location: 0, length: 12),
            text: "Done",
            headingIndex: nil,
            indentLevel: 0
        )]
        view.showsIncompleteOnly = true

        #expect((view.accessibilityValue() as? String) == "No incomplete tasks")
    }

    @Test
    func taskPanelFiltersCompletedWorkWithoutLosingProgress() {
        let view = TaskPanelView()
        view.tasks = [
            TaskItem(
                isChecked: true,
                markRange: NSRange(location: 3, length: 1),
                contentRange: NSRange(location: 0, length: 12),
                text: "Done",
                headingIndex: nil,
                indentLevel: 0
            ),
            TaskItem(
                isChecked: false,
                markRange: NSRange(location: 16, length: 1),
                contentRange: NSRange(location: 13, length: 12),
                text: "Open",
                headingIndex: nil,
                indentLevel: 0
            ),
        ]

        #expect(view.progress == (done: 1, total: 2))
        #expect(view.visibleTaskCountForTesting == 2)
        #expect(view.preferredWidth == 336)

        view.showsIncompleteOnly = true

        #expect(view.visibleTaskCountForTesting == 1)
        #expect(view.progress == (done: 1, total: 2))
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
    func inspectorSectionNavigationStaysInSync() {
        let host = InspectorHostView()
        host.setContent(NSView(), section: .search)
        host.setContent(NSView(), section: .tasks)

        host.select(.search)
        #expect(host.selectedSection == .search)
        #expect((host.accessibilityValue() as? String) == "Search section")
    }
}
