import Foundation
import Testing
@testable import MarkdownCore

@Suite struct TaskWorklistTests {

    // MARK: Fixture helpers
    //
    // TaskItems are built by hand through the memberwise init: the worklist is
    // a pure derivation, so no parser needs to be involved.  Ranges carry
    // plausible offsets only so the tests can prove they survive the flattening
    // into `markOffset` / `contentOffset`.

    private func task(
        _ text: String,
        checked: Bool = false,
        heading: Int? = nil,
        indent: Int = 0,
        mark: Int = 0
    ) -> TaskItem {
        TaskItem(
            isChecked: checked,
            markRange: NSRange(location: mark, length: 1),
            contentRange: NSRange(location: mark + 4, length: text.utf16.count),
            text: text,
            headingIndex: heading,
            indentLevel: indent
        )
    }

    private func headings(_ titles: String...) -> [HeadingNode] {
        titles.map {
            HeadingNode(
                level: 1, title: $0,
                range: NSRange(location: 0, length: 1),
                contentRange: NSRange(location: 0, length: 1),
                sectionRange: NSRange(location: 0, length: 1)
            )
        }
    }

    // MARK: Empty input

    @Test func emptyInputYieldsAnEmptyWorklist() {
        let worklist = TaskWorklist(tasks: [], headings: [])
        #expect(worklist.sections.isEmpty)
        #expect(worklist.totalCount == 0)
        #expect(worklist.doneCount == 0)
        #expect(worklist.upNext == nil)
        #expect(worklist.segments.isEmpty)
        #expect(worklist.statusLine == "")
        #expect(worklist.statusReport == "")
    }

    // MARK: Sections

    @Test func tasksBeforeAnyHeadingLandInTheDocumentSection() {
        let worklist = TaskWorklist(tasks: [
            task("alpha", mark: 3),
            task("beta", checked: true, mark: 20),
        ], headings: headings("Later"))
        #expect(worklist.sections.count == 1)
        #expect(worklist.sections[0].headingIndex == nil)
        #expect(worklist.sections[0].title == "Document")
        #expect(worklist.sections[0].openCount == 1)
        #expect(worklist.sections[0].doneCount == 1)
        // The range offsets survive the flattening into Entry.
        #expect(worklist.sections[0].entries[0].markOffset == 3)
        #expect(worklist.sections[0].entries[0].contentOffset == 7)
        #expect(worklist.sections[0].entries[1].markOffset == 20)
    }

    @Test func sectionsAppearInOrderOfTheirFirstTask() {
        let worklist = TaskWorklist(tasks: [
            task("preamble"),
            task("a", heading: 0),
            task("b", heading: 1),
            // Back-reference: appends to the existing section rather than
            // opening a new one, and the section order is untouched.
            task("c", heading: 0),
            task("d", heading: 1),
        ], headings: headings("Intro", "Later"))
        #expect(worklist.sections.map(\.title) == ["Document", "Intro", "Later"])
        #expect(worklist.sections.map(\.headingIndex) == [nil, 0, 1])
        #expect(worklist.sections[1].entries.map(\.text) == ["a", "c"])
        #expect(worklist.sections[2].entries.map(\.text) == ["b", "d"])
        #expect(worklist.totalCount == 5)
        #expect(worklist.doneCount == 0)
    }

    @Test func headingsWithoutTasksGetNoSection() {
        let worklist = TaskWorklist(tasks: [
            task("only", heading: 1),
        ], headings: headings("Empty", "Full"))
        #expect(worklist.sections.map(\.title) == ["Full"])
        #expect(worklist.sections[0].headingIndex == 1)
    }

    // MARK: Open / done partitioning

    @Test func openAndDonePartitionsKeepDocumentOrder() {
        let worklist = TaskWorklist(tasks: [
            task("one"),
            task("two", checked: true),
            task("three"),
            task("four", checked: true),
            task("five"),
        ], headings: [])
        let section = worklist.sections[0]
        #expect(section.entries.map(\.text) == ["one", "two", "three", "four", "five"])
        #expect(section.openEntries.map(\.text) == ["one", "three", "five"])
        #expect(section.doneEntries.map(\.text) == ["two", "four"])
        #expect(section.openCount == 3)
        #expect(section.doneCount == 2)
        // The partitions are views of the same tasks, not renumbered copies.
        #expect(section.openEntries.map(\.taskIndex) == [0, 2, 4])
        #expect(section.doneEntries.map(\.taskIndex) == [1, 3])
    }

    // MARK: Up next

    @Test func upNextIsTheFirstOpenTaskInDocumentOrder() {
        let worklist = TaskWorklist(tasks: [
            task("finished", checked: true, heading: 0),
            task("also finished", checked: true, heading: 0),
            task("waiting", heading: 1),
            task("later", heading: 1),
        ], headings: headings("Done", "Open"))
        // A fully-done section is skipped, not just a fully-done task.
        #expect(worklist.upNext?.sectionIndex == 1)
        #expect(worklist.upNext?.entry.text == "waiting")
        #expect(worklist.upNext?.entry.taskIndex == 2)
        #expect(worklist.upNext?.entry == worklist.sections[1].openEntries[0])
    }

    @Test func upNextIsNilWhenEverythingIsDone() {
        let worklist = TaskWorklist(tasks: [
            task("a", checked: true),
            task("b", checked: true, heading: 0),
        ], headings: headings("H"))
        #expect(worklist.upNext == nil)
        #expect(worklist.doneCount == worklist.totalCount)
    }

    // MARK: Segments

    @Test func segmentWeightsSumToOneAndCompletionIsPerSection() {
        let worklist = TaskWorklist(tasks: [
            task("a1", heading: 0),
            task("a2", checked: true, heading: 0),
            task("a3", heading: 0),
            task("b1", checked: true, heading: 1),
        ], headings: headings("A", "B"))
        #expect(worklist.segments == [
            TaskWorklist.Segment(
                sectionIndex: 0, title: "A", taskCount: 3, doneCount: 1,
                weight: 3.0 / 4.0, completion: 1.0 / 3.0
            ),
            TaskWorklist.Segment(
                sectionIndex: 1, title: "B", taskCount: 1, doneCount: 1,
                weight: 1.0 / 4.0, completion: 1.0
            ),
        ])
        let weightSum = worklist.segments.reduce(0.0) { $0 + $1.weight }
        #expect(abs(weightSum - 1.0) < 1e-12)
    }

    // MARK: Status line

    @Test func statusLineCoversEmptyPartialAndComplete() {
        #expect(TaskWorklist(tasks: [], headings: []).statusLine == "")

        let allDone = TaskWorklist(tasks: [
            task("a", checked: true),
            task("b", checked: true),
        ], headings: [])
        #expect(allDone.statusLine == "All 2 tasks done")

        // The separator is space, U+00B7 middle dot, space.
        let partial = TaskWorklist(tasks: [
            task("a", checked: true),
            task("b"),
            task("c"),
        ], headings: [])
        #expect(partial.statusLine == "1 of 3 done · next: b")
    }


    // MARK: Status report

    @Test func statusReportRendersTwoSectionsWithIndentation() {
        let worklist = TaskWorklist(tasks: [
            task("alpha", checked: true, heading: 0),
            task("beta", heading: 0, indent: 1),
            task("gamma", heading: 1),
        ], headings: headings("Intro", "Later"))
        // Em dash (U+2014) after the bold summary; no trailing newline.
        #expect(worklist.statusReport == """
        **1 of 3 done** — next: beta

        ## Intro (1/2)
        - [x] alpha
          - [ ] beta

        ## Later (0/1)
        - [ ] gamma
        """)
    }

    @Test func statusReportForAnEmptyWorklistIsEmpty() {
        #expect(TaskWorklist(tasks: [], headings: []).statusReport == "")
    }

    // MARK: Singular

    @Test func aSingleFinishedTaskUsesTheSingularEverywhere() {
        let worklist = TaskWorklist(tasks: [task("alpha", checked: true)], headings: [])
        #expect(worklist.statusLine == "1 task done")
        #expect(worklist.statusReport == """
        **1 task done**

        ## Document (1/1)
        - [x] alpha
        """)
        #expect(worklist.upNext == nil)
    }

    // MARK: Value semantics

    @Test func worklistsWithEqualInputsAreEqual() {
        let tasks = [task("a"), task("b", checked: true, heading: 0)]
        let heads = headings("H")
        #expect(TaskWorklist(tasks: tasks, headings: heads)
            == TaskWorklist(tasks: tasks, headings: heads))
    }

    // MARK: Robustness

    /// The panel rebuilds on every keystroke and can pair a task array captured
    /// one parse earlier than the headings it arrives with.  An out-of-range
    /// `headingIndex` must degrade to the "Document" section, never trap — the
    /// crash that took the Tasks button down lived exactly here.
    @Test func anOutOfRangeHeadingIndexFallsBackToDocument() {
        let tasks = [
            task("orphan", heading: 7),           // no such heading
            task("valid", checked: true, heading: 0),
        ]
        let worklist = TaskWorklist(tasks: tasks, headings: headings("Only"))
        #expect(worklist.totalCount == 2)
        // The orphan joined "Document"; the valid task stayed under its heading.
        let titles = worklist.sections.map(\.title)
        #expect(titles.contains("Document"))
        #expect(titles.contains("Only"))
        let document = worklist.sections.first { $0.headingIndex == nil }
        #expect(document?.entries.map(\.text) == ["orphan"])
        #expect(worklist.upNext?.entry.text == "orphan")
    }

    @Test func aTaskWhoseHeadingIndexIsValidSurvives() {
        let worklist = TaskWorklist(
            tasks: [task("real", heading: 1)],
            headings: headings("A", "B")
        )
        #expect(worklist.sections.first?.title == "B")
        #expect(worklist.sections.first?.headingIndex == 1)
    }
}
