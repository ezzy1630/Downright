import AppKit
import Foundation
import Testing
import MarkdownCore
import MarkdownRender
@testable import DownrightApp

@Suite(.serialized)
@MainActor
struct TableEditorTests {
    private let source = "| Name | Count |\n| :--- | ---: |\n| Ada | 3 |\n| Grace | 4 |\n"

    @Test
    func loadsRowsColumnsAndSourceRange() throws {
        let editor = TableEditorView(document: MarkdownParser.parse(source))
        #expect(editor.rowCountForTesting == 3)
        #expect(editor.columnCountForTesting == 2)
        #expect(editor.sourceRangeForTesting.length > 0)
    }

    @Test
    func forwardsCellEditAsOneSourceProposal() throws {
        let editor = TableEditorView(document: MarkdownParser.parse(source))
        let delegate = ProposalRecorder()
        editor.delegate = delegate
        editor.apply(operation: .setCell(row: 1, column: 0, text: "Ada Lovelace"))
        let proposal = try #require(delegate.proposal)
        #expect(proposal.summary == "Edit table cell")
        #expect(proposal.applying(to: source)?.contains("Ada Lovelace") == true)
    }

    @Test
    func forwardsStructureAndAlignmentOperations() throws {
        let editor = TableEditorView(document: MarkdownParser.parse(source))
        let delegate = ProposalRecorder()
        editor.delegate = delegate

        editor.apply(operation: .insertColumn(index: 1, header: "Tag", cells: ["a", "b"]))
        #expect(try #require(delegate.proposal).summary == "Insert table column")

        editor.apply(operation: .setAlignment(column: 0, alignment: .center))
        #expect(try #require(delegate.proposal).summary == "Set table alignment")
    }

    @Test
    func hostApplicationUsesOneUndoStep() throws {
        let document = MarkdownDocument()
        document.adopt(text: source, displayURL: nil)
        let editor = TableEditorView(document: document.parsed)
        let delegate = ProposalRecorder()
        editor.delegate = delegate
        editor.apply(operation: .setCell(row: 1, column: 1, text: "5"))
        let proposal = try #require(delegate.proposal)
        #expect(document.replace(proposal.range, with: proposal.replacement, actionName: proposal.summary))
        #expect(document.text.contains("| 5 |"))
        #expect(document.undoManager.canUndo)
        document.undoManager.undo()
        #expect(document.text == source)
    }

    @Test
    func sourceRequestUsesWholeTableRange() {
        let editor = TableEditorView(document: MarkdownParser.parse(source))
        let delegate = ProposalRecorder()
        editor.delegate = delegate
        editor.requestSourceForTesting()
        #expect(delegate.sourceRange == editor.sourceRangeForTesting)
    }
}

@MainActor
private final class ProposalRecorder: TableEditorDelegate {
    var proposal: TableEditProposal?
    var sourceRange: NSRange?

    func tableEditor(_ editor: TableEditorView, didApply proposal: TableEditProposal) {
        self.proposal = proposal
    }

    func tableEditor(_ editor: TableEditorView, didRequestSource range: NSRange) {
        sourceRange = range
    }
}
