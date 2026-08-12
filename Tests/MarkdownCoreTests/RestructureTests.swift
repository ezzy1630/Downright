import Foundation
import Testing
@testable import MarkdownCore

@Suite struct RestructureTests {

    private func apply(_ text: String, _ edits: [TextEdit]) -> String { edits.applied(to: text) }

    // MARK: Promote / demote

    @Test func promoteMovesTheWholeSubtree() {
        let text = "# Top\n\n## Section\n\n### Sub\n\n#### Deep\n\n## Other\n"
        let doc = MarkdownParser.parse(text)
        let out = apply(text, Restructure.promoteHeading(doc, headingIndex: 1))
        #expect(out == "# Top\n\n# Section\n\n## Sub\n\n### Deep\n\n## Other\n")
    }

    @Test func demoteMovesTheWholeSubtree() {
        let text = "# Top\n\n## Section\n\n### Sub\n\n## Other\n"
        let doc = MarkdownParser.parse(text)
        let out = apply(text, Restructure.demoteHeading(doc, headingIndex: 1))
        #expect(out == "# Top\n\n### Section\n\n#### Sub\n\n## Other\n")
    }

    @Test func promoteDemoteRoundTrips() {
        let text = "# Top\n\n## Section\n\n### Sub\n\n## Other\n"
        let doc = MarkdownParser.parse(text)
        let demoted = apply(text, Restructure.demoteHeading(doc, headingIndex: 1))
        let back = apply(demoted, Restructure.promoteHeading(MarkdownParser.parse(demoted), headingIndex: 1))
        #expect(back == text)
    }

    @Test func setsAnExactHeadingLevelAndMovesItsSubtree() {
        let text = "# Top\n\n## Section\n\n### Child\n\n## Other\n"
        let doc = MarkdownParser.parse(text)
        let out = apply(text, Restructure.setHeadingLevel(doc, headingIndex: 1, level: 4))
        #expect(out == "# Top\n\n#### Section\n\n##### Child\n\n## Other\n")
        #expect(Restructure.setHeadingLevel(doc, headingIndex: 1, level: 2).isEmpty)
        #expect(Restructure.setHeadingLevel(doc, headingIndex: 1, level: 0).isEmpty)
    }

    @Test func headingToBodyPreservesTitlesAndRemovesClosingMarkers() {
        let compact = "#   Title\n"
        #expect(apply(
            compact,
            Restructure.headingToBodyText(MarkdownParser.parse(compact), headingIndex: 0)
        ) == "Title\n")

        let closed = "  ###   Title ###\n"
        #expect(apply(
            closed,
            Restructure.headingToBodyText(MarkdownParser.parse(closed), headingIndex: 0)
        ) == "  Title\n")
    }

    @Test func headingToBodySupportsSetext() {
        let text = "Title\n=====\n\nBody\n"
        #expect(apply(
            text,
            Restructure.headingToBodyText(MarkdownParser.parse(text), headingIndex: 0)
        ) == "Title\n\nBody\n")
    }

    @Test func clampsAtTheEnds() {
        let top = MarkdownParser.parse("# A\n\n## B\n")
        #expect(Restructure.promoteHeading(top, headingIndex: 0).isEmpty)

        let deep = MarkdownParser.parse("###### A\n")
        #expect(Restructure.demoteHeading(deep, headingIndex: 0).isEmpty)

        // A subtree that would push a descendant past H6 is refused whole,
        // rather than flattened.
        let nested = MarkdownParser.parse("##### A\n\n###### B\n")
        let out = apply("##### A\n\n###### B\n", Restructure.demoteHeading(nested, headingIndex: 0))
        #expect(out == "##### A\n\n###### B\n")
    }

    // MARK: Move section — §14 calls this out as harder than it looks

    @Test func moveSectionPreservesBlankLineStructure() {
        let text = "# Doc\n\n## A\n\nAlpha body.\n\n## B\n\nBeta body.\n\n## C\n\nGamma body.\n"
        let doc = MarkdownParser.parse(text)
        // Move C before A.
        let out = apply(text, Restructure.moveSection(doc, headingIndex: 3, before: 1))
        #expect(out == "# Doc\n\n## C\n\nGamma body.\n\n## A\n\nAlpha body.\n\n## B\n\nBeta body.\n")
    }

    @Test func moveSectionCarriesTheWholeSubtree() {
        let text = "## A\n\nbody a\n\n### A1\n\nbody a1\n\n## B\n\nbody b\n"
        let doc = MarkdownParser.parse(text)
        let out = apply(text, Restructure.moveSection(doc, headingIndex: 0, before: 3))
        #expect(out == "## B\n\nbody b\n\n## A\n\nbody a\n\n### A1\n\nbody a1\n")
    }

    @Test func moveSectionToTheEndKeepsTheFinalNewline() {
        let text = "## A\n\nbody a\n\n## B\n\nbody b\n"
        let doc = MarkdownParser.parse(text)
        let out = apply(text, Restructure.moveSection(doc, headingIndex: 0, before: doc.headings.count))
        #expect(out == "## B\n\nbody b\n\n## A\n\nbody a\n")
    }

    /// The awkward case: the last section has no trailing newline to carry, so
    /// it borrows the one before it and the document's final-newline state is
    /// preserved either way (§3.1).
    @Test func moveSectionHandlesAMissingFinalNewline() {
        let text = "## A\n\nbody a\n\n## B\n\nbody b"
        let doc = MarkdownParser.parse(text)
        let out = apply(text, Restructure.moveSection(doc, headingIndex: 1, before: 0))
        #expect(out == "## B\n\nbody b\n\n## A\n\nbody a")
        #expect(!out.hasSuffix("\n"))
    }

    @Test func moveSectionIsANoOpWhenTheTargetIsInsideIt() {
        let text = "## A\n\nbody\n\n### A1\n\nsub\n\n## B\n\nb\n"
        let doc = MarkdownParser.parse(text)
        #expect(Restructure.moveSection(doc, headingIndex: 0, before: 1).isEmpty)
        #expect(Restructure.moveSection(doc, headingIndex: 0, before: 0).isEmpty)
    }

    @Test func moveSectionSurvivesAnArbitraryPermutation() {
        var text = "# Doc\n\n## A\n\na\n\n## B\n\nb\n\n## C\n\nc\n\n## D\n\nd\n"
        for (from, to) in [(4, 1), (1, 4), (2, 1), (3, 2)] {
            let doc = MarkdownParser.parse(text)
            guard doc.headings.indices.contains(from) else { continue }
            text = apply(text, Restructure.moveSection(doc, headingIndex: from, before: to))
            let reparsed = MarkdownParser.parse(text)
            // No section ever loses or gains a blank line separator.
            #expect(!text.contains("\n\n\n"), "grew a blank line: \(text.debugDescription)")
            #expect(reparsed.headings.count == 5)
            #expect(Set(reparsed.headings.map(\.title)) == ["Doc", "A", "B", "C", "D"])
        }
    }

    /// A classic-Mac file (lone `\r` terminators) must stay all-`\r` through a
    /// section move: the separators `moveSection` synthesises used to be hard
    /// `\n`, mixing endings in a file `DocumentIO` will then refuse to touch.
    @Test func moveSectionKeepsLoneCRLineEndings() {
        let text = "# One\r\r# Two\r\r# Three\r"
        let doc = MarkdownParser.parse(text)
        let out = apply(text, Restructure.moveSection(doc, headingIndex: 2, before: 0))
        #expect(out == "# Three\r\r# One\r\r# Two\r")
    }

    @Test func moveSectionKeepsCRLFLineEndings() {
        let text = "# One\r\n\r\n# Two\r\n\r\n# Three\r\n"
        let doc = MarkdownParser.parse(text)
        let out = apply(text, Restructure.moveSection(doc, headingIndex: 2, before: 0))
        #expect(out == "# Three\r\n\r\n# One\r\n\r\n# Two\r\n")
    }

    // MARK: Move block

    @Test func moveBlockSwapsSiblingsAndKeepsTheGap() {
        let text = "First para.\n\nSecond para.\n\nThird para.\n"
        let doc = MarkdownParser.parse(text)
        let down = apply(text, Restructure.moveBlock(doc, containing: 2, .down))
        #expect(down == "Second para.\n\nFirst para.\n\nThird para.\n")

        let up = apply(text, Restructure.moveBlock(doc, containing: 16, .up))
        #expect(up == "Second para.\n\nFirst para.\n\nThird para.\n")
    }

    @Test func moveBlockActsOnTheListItemNotTheParagraphInsideIt() {
        let text = "- one\n- two\n- three\n"
        let doc = MarkdownParser.parse(text)
        let out = apply(text, Restructure.moveBlock(doc, containing: 8, .up))
        #expect(out == "- two\n- one\n- three\n")
    }

    @Test func moveBlockAtTheBoundaryIsANoOp() {
        let text = "a\n\nb\n"
        let doc = MarkdownParser.parse(text)
        #expect(Restructure.moveBlock(doc, containing: 0, .up).isEmpty)
        #expect(Restructure.moveBlock(doc, containing: 3, .down).isEmpty)
    }

    // MARK: Conversion

    @Test func convertsBetweenEveryForm() {
        let text = "alpha\nbeta\n"
        let doc = MarkdownParser.parse(text)
        let all = NSRange(location: 0, length: (text as NSString).length)
        #expect(apply(text, Restructure.convert(doc, range: all, to: .bulletList)) == "- alpha\n- beta\n")
        #expect(apply(text, Restructure.convert(doc, range: all, to: .numberedList)) == "1. alpha\n2. beta\n")
        #expect(apply(text, Restructure.convert(doc, range: all, to: .taskList)) == "- [ ] alpha\n- [ ] beta\n")
        #expect(apply(text, Restructure.convert(doc, range: all, to: .blockquote)) == "> alpha\n> beta\n")
    }

    @Test func conversionRoundTripsBackToParagraph() {
        let text = "alpha\nbeta\n"
        for form in [ListConversion.bulletList, .numberedList, .taskList, .blockquote] {
            let doc = MarkdownParser.parse(text)
            let all = NSRange(location: 0, length: (text as NSString).length)
            let converted = apply(text, Restructure.convert(doc, range: all, to: form))
            let convertedDoc = MarkdownParser.parse(converted)
            let back = apply(converted, Restructure.convert(
                convertedDoc,
                range: NSRange(location: 0, length: (converted as NSString).length),
                to: .paragraph
            ))
            #expect(back == text, "\(form.rawValue) did not round trip: \(converted.debugDescription)")
        }
    }

    @Test func conversionKeepsIndentation() {
        let text = "  alpha\n"
        let doc = MarkdownParser.parse(text)
        let all = NSRange(location: 0, length: (text as NSString).length)
        #expect(apply(text, Restructure.convert(doc, range: all, to: .bulletList)) == "  - alpha\n")
    }

    // MARK: Sorting

    @Test func sortsAlphabetically() {
        let text = "- charlie\n- alpha\n- bravo\n"
        let doc = MarkdownParser.parse(text)
        #expect(apply(text, Restructure.sortList(doc, containing: 2, order: .alphabetical))
            == "- alpha\n- bravo\n- charlie\n")
        #expect(apply(text, Restructure.sortList(doc, containing: 2, order: .reverseAlphabetical))
            == "- charlie\n- bravo\n- alpha\n")
    }

    @Test func sortsByCheckboxState() {
        let text = "- [x] done\n- [ ] todo\n- [x] also done\n- [ ] later\n"
        let doc = MarkdownParser.parse(text)
        let out = apply(text, Restructure.sortList(doc, containing: 2, order: .uncheckedFirst))
        #expect(out == "- [ ] todo\n- [ ] later\n- [x] done\n- [x] also done\n")
    }

    @Test func sortingAnOrderedListRenumbers() {
        let text = "1. charlie\n2. alpha\n3. bravo\n"
        let doc = MarkdownParser.parse(text)
        #expect(apply(text, Restructure.sortList(doc, containing: 3, order: .alphabetical))
            == "1. alpha\n2. bravo\n3. charlie\n")
    }

    // MARK: Table of contents

    @Test func generatesAnIndentedTableOfContents() {
        let doc = MarkdownParser.parse("# Doc\n\n## A\n\n### A1\n\n## B\n\n#### Deep\n")
        #expect(Restructure.tableOfContents(doc, maxLevel: 3) == """
        - [Doc](#doc)
          - [A](#a)
            - [A1](#a1)
          - [B](#b)
        """)
        #expect(Restructure.tableOfContents(doc, maxLevel: 1) == "- [Doc](#doc)")
    }

    // MARK: Tasks

    @Test func toggleTaskIsAOneCharacterEdit() {
        let text = "- [ ] alpha\n- [x] beta\n"
        let doc = MarkdownParser.parse(text)
        let check = Restructure.toggleTask(doc, atMarkOffset: doc.tasks[0].markRange.location)
        #expect(check?.range.length == 1)
        #expect(check?.replacement == "x")
        #expect(apply(text, [check!]) == "- [x] alpha\n- [x] beta\n")

        let uncheck = Restructure.toggleTask(doc, atMarkOffset: doc.tasks[1].markRange.location)
        #expect(uncheck?.replacement == " ")
        #expect(apply(text, [uncheck!]) == "- [ ] alpha\n- [ ] beta\n")
    }

    @Test func toggleTaskOutsideATaskIsNil() {
        let doc = MarkdownParser.parse("Just a paragraph.\n")
        #expect(Restructure.toggleTask(doc, atMarkOffset: 3) == nil)
    }

    // MARK: Tasks — insert

    @Test func insertTaskGoesAfterTheLastTaskOfTheSection() {
        let text = "# A\n\n- [ ] one\n- [ ] two\n\n# B\n\n- [ ] three\n"
        let doc = MarkdownParser.parse(text)
        let out = apply(text, Restructure.insertTask(doc, text: "new", headingIndex: 0))
        #expect(out == "# A\n\n- [ ] one\n- [ ] two\n- [ ] new\n\n# B\n\n- [ ] three\n")
    }

    @Test func insertTaskLandsAfterTheWholeChildBlock() {
        // The anchor is the last matching task, and its block extends over
        // nested children, so the new line never splits a family.
        let text = "# S\n\n- [ ] a\n- [ ] b\n  - [ ] b1\n  - [ ] b2\n"
        let doc = MarkdownParser.parse(text)
        let out = apply(text, Restructure.insertTask(doc, text: "new", headingIndex: 0))
        #expect(out == "# S\n\n- [ ] a\n- [ ] b\n  - [ ] b1\n  - [ ] b2\n- [ ] new\n")

        // Non-task children indented under the anchor ride along too.
        let continuation = "# S\n\n- [ ] a\n  - plain child\n\n# T\n\n- [ ] t\n"
        let out2 = apply(
            continuation,
            Restructure.insertTask(MarkdownParser.parse(continuation), text: "new", headingIndex: 0)
        )
        #expect(out2 == "# S\n\n- [ ] a\n  - plain child\n- [ ] new\n\n# T\n\n- [ ] t\n")
    }

    @Test func insertTaskIntoHeadinglessDocument() {
        let text = "- [ ] one\n- [ ] two\n"
        let doc = MarkdownParser.parse(text)
        let out = apply(text, Restructure.insertTask(doc, text: "new", headingIndex: nil))
        #expect(out == "- [ ] one\n- [ ] two\n- [ ] new\n")
    }

    @Test func insertTaskIntoEmptyDocument() {
        let doc = MarkdownParser.parse("")
        #expect(apply("", Restructure.insertTask(doc, text: "new", headingIndex: nil)) == "- [ ] new\n")
    }

    @Test func insertTaskIntoDocumentWithoutTrailingNewline() {
        let text = "- [ ] one"
        let doc = MarkdownParser.parse(text)
        let out = apply(text, Restructure.insertTask(doc, text: "new", headingIndex: nil))
        #expect(out == "- [ ] one\n- [ ] new\n")
    }

    @Test func insertTaskWithoutAMatchingSectionAppendsWithSeparation() {
        let text = "# A\n\n- [ ] x\n"
        let doc = MarkdownParser.parse(text)
        #expect(apply(text, Restructure.insertTask(doc, text: "new", headingIndex: 1))
            == "# A\n\n- [ ] x\n\n- [ ] new\n")

        // Already blank at EOF: no extra separation.
        let blank = "# A\n\n- [ ] x\n\n"
        #expect(apply(blank, Restructure.insertTask(MarkdownParser.parse(blank), text: "new", headingIndex: 1))
            == "# A\n\n- [ ] x\n\n- [ ] new\n")

        // No trailing newline at all: the separator has to create the blank line.
        let prose = "Just prose."
        #expect(apply(prose, Restructure.insertTask(MarkdownParser.parse(prose), text: "new", headingIndex: nil))
            == "Just prose.\n\n- [ ] new\n")
    }

    @Test func insertTaskRejectsWhitespaceOnlyText() {
        let doc = MarkdownParser.parse("- [ ] one\n")
        #expect(Restructure.insertTask(doc, text: "  \n\t ", headingIndex: nil).isEmpty)
    }

    // MARK: Tasks — move

    @Test func moveTaskDownOneSibling() {
        let text = "- [ ] a\n- [ ] b\n- [ ] c\n"
        let doc = MarkdownParser.parse(text)
        #expect(apply(text, Restructure.moveTask(doc, taskIndex: 0, before: 2))
            == "- [ ] b\n- [ ] a\n- [ ] c\n")
    }

    @Test func moveTaskToTheEnd() {
        let text = "- [ ] a\n- [ ] b\n- [ ] c\n"
        let doc = MarkdownParser.parse(text)
        #expect(apply(text, Restructure.moveTask(doc, taskIndex: 0, before: nil))
            == "- [ ] b\n- [ ] c\n- [ ] a\n")
    }

    @Test func moveTaskUp() {
        let text = "- [ ] a\n- [ ] b\n- [ ] c\n"
        let doc = MarkdownParser.parse(text)
        #expect(apply(text, Restructure.moveTask(doc, taskIndex: 2, before: 0))
            == "- [ ] c\n- [ ] a\n- [ ] b\n")
    }

    @Test func moveTaskCarriesItsChildren() {
        let text = "- [ ] a\n  - [ ] a1\n- [ ] b\n"
        let doc = MarkdownParser.parse(text)
        // Lifting b over a leaves a's child attached to a.
        #expect(apply(text, Restructure.moveTask(doc, taskIndex: 2, before: 0))
            == "- [ ] b\n- [ ] a\n  - [ ] a1\n")
        // Moving a to the end carries a1 along with it.
        #expect(apply(text, Restructure.moveTask(doc, taskIndex: 0, before: nil))
            == "- [ ] b\n- [ ] a\n  - [ ] a1\n")
    }

    @Test func moveTaskTreatsBlankLineSplitListsAsOneSiblingGroup() {
        let text = "- [ ] a\n\n- [ ] b\n"
        let doc = MarkdownParser.parse(text)
        // The blank line is the join's, not either task's — it stays put.
        #expect(apply(text, Restructure.moveTask(doc, taskIndex: 1, before: 0))
            == "- [ ] b\n- [ ] a\n\n")
    }

    @Test func moveTaskRefusesAnotherSection() {
        let text = "# A\n\n- [ ] a\n\n# B\n\n- [ ] b\n"
        let doc = MarkdownParser.parse(text)
        #expect(Restructure.moveTask(doc, taskIndex: 1, before: 0).isEmpty)
        #expect(Restructure.moveTask(doc, taskIndex: 0, before: 1).isEmpty)
    }

    @Test func moveTaskRefusesAnotherIndentLevel() {
        let text = "- [ ] a\n  - [ ] a1\n- [ ] b\n"
        let doc = MarkdownParser.parse(text)
        // Child before its parent, and parent before its child: re-parenting,
        // not reordering.
        #expect(Restructure.moveTask(doc, taskIndex: 1, before: 0).isEmpty)
        #expect(Restructure.moveTask(doc, taskIndex: 0, before: 1).isEmpty)
    }

    @Test func moveTaskAlreadyInPositionIsANoOp() {
        let text = "- [ ] a\n- [ ] b\n"
        let doc = MarkdownParser.parse(text)
        #expect(Restructure.moveTask(doc, taskIndex: 0, before: 0).isEmpty)
        #expect(Restructure.moveTask(doc, taskIndex: 1, before: nil).isEmpty)
    }

    @Test func moveTaskPreservesAMissingFinalNewline() {
        let text = "- [ ] a\n- [ ] b"
        let doc = MarkdownParser.parse(text)
        // Last to first: the cut borrows the newline before the block.
        #expect(apply(text, Restructure.moveTask(doc, taskIndex: 1, before: 0))
            == "- [ ] b\n- [ ] a")
        // First to last: the paste brings its own leading separator.
        #expect(apply(text, Restructure.moveTask(doc, taskIndex: 0, before: nil))
            == "- [ ] b\n- [ ] a")
    }

    // MARK: Tables (§6.3)

    private let table = "| a | bb |\n| --- | --- |\n| 1 | 2 |\n| 333 | 4 |\n"

    @Test func realignsTableSource() {
        let doc = MarkdownParser.parse(table)
        let range = doc.root.children[0].range
        let out = apply(table, Restructure.realignTable(doc, tableRange: range))
        #expect(out == "| a   | bb  |\n| --- | --- |\n| 1   | 2   |\n| 333 | 4   |\n")
    }

    @Test func setsColumnAlignment() {
        let doc = MarkdownParser.parse(table)
        let range = doc.root.children[0].range
        let out = apply(table, Restructure.setColumnAlignment(doc, tableRange: range, column: 1, alignment: .right))
        // The alignment colon lives inside the column's existing width rather
        // than widening it, so realigning twice is a fixed point.
        #expect(out.contains("| --- | --: |"))
        #expect(out.contains("| a   |  bb |"))
    }

    @Test func insertsAndDeletesRows() {
        let doc = MarkdownParser.parse(table)
        let range = doc.root.children[0].range

        let inserted = apply(table, Restructure.insertRow(doc, tableRange: range, afterRow: 1))
        #expect(inserted == "| a   | bb  |\n| --- | --- |\n| 1   | 2   |\n|     |     |\n| 333 | 4   |\n")

        let deleted = apply(table, Restructure.deleteRow(doc, tableRange: range, row: 1))
        #expect(deleted == "| a   | bb  |\n| --- | --- |\n| 333 | 4   |\n")

        // A GFM table without a header is not a table.
        #expect(Restructure.deleteRow(doc, tableRange: range, row: 0).isEmpty)
    }
}
