import Foundation
import Testing
@testable import MarkdownCore

@Suite struct TableEditingTests {
    private func proposal(_ source: String, _ operation: TableEditOperation) throws -> TableEditProposal {
        let result = TableEditing.propose(MarkdownParser.parse(source), operation: operation)
        return try #require(result.proposal)
    }

    @Test func cellEditIsLocalAndEscapesPipes() throws {
        let source = "| A | B |\n|---|---|\n| one | two |\n"
        let edit = try proposal(source, .setCell(row: 1, column: 0, text: "x|y"))
        let output = try #require(edit.applying(to: source))
        #expect(output == "| A | B |\n|---|---|\n| x\\|y | two |\n")
        #expect(edit.range.length < (source as NSString).length)
    }

    @Test func alignmentOnlyRewritesDelimiter() throws {
        let source = "  | A | B |\r\n  |---|---|\r\n  | one | two |\r\n"
        let edit = try proposal(source, .setAlignment(column: 1, alignment: .right))
        #expect(edit.applying(to: source) == "  | A | B |\r\n  |---|--:|\r\n  | one | two |\r\n")
    }

    @Test func insertRowAfterDelimiterPreservesIndentation() throws {
        let source = "  | A | B |\n  |---|---|\n  | one | two |\n"
        let edit = try proposal(source, .insertRow(index: 1, cells: ["new", "row"]))
        #expect(edit.applying(to: source) == "  | A | B |\n  |---|---|\n  | new | row |\n  | one | two |\n")
    }

    @Test func insertRowPadsMissingCells() throws {
        let source = "| A | B | C |\n|---|---|---|\n| one | two | three |\n"
        let edit = try proposal(source, .insertRow(index: 1, cells: ["new"]))
        #expect(edit.applying(to: source) == "| A | B | C |\n|---|---|---|\n| new |  |  |\n| one | two | three |\n")
    }

    @Test func insertColumnAcceptsOneValuePerBodyRow() throws {
        let source = "| A |\n|---|\n| one |\n| two |\n| three |\n"
        let edit = try proposal(
            source,
            .insertColumn(index: 1, header: "B", cells: ["1", "2", "3"])
        )
        #expect(edit.applying(to: source) == "| A | B |\n|---|---|\n| one | 1 |\n| two | 2 |\n| three | 3 |\n")
    }

    @Test func columnOperationsKeepEscapedPipes() throws {
        let source = "| A | B | C |\n|---|---|---|\n| a\\|x | b | c |\n"
        let moved = try proposal(source, .moveColumn(from: 0, to: 2))
        let output = try #require(moved.applying(to: source))
        #expect(output.contains("| b | c | a\\|x |"))
        let deleted = try proposal(source, .deleteColumn(index: 1))
        #expect(deleted.applying(to: source)?.contains("| A | C |") == true)
    }

    @Test func cannotDeleteHeaderAndRejectsStaleSource() throws {
        let source = "| A | B |\n|---|---|\n| one | two |\n"
        let result = TableEditing.propose(MarkdownParser.parse(source), operation: .deleteRow(index: 0))
        #expect(result.proposal == nil)
        #expect(result.fallback == .cannotDeleteHeader)
        let edit = try proposal(source, .setCell(row: 1, column: 1, text: "new"))
        #expect(edit.applying(to: source.replacingOccurrences(of: "two", with: "old")) == nil)
    }

    @Test func spacedDelimiterDoesNotDuplicateCellPadding() throws {
        let source = "| A | B |\n| --- | --- |\n| one | two |\n"
        let edit = try proposal(source, .setAlignment(column: 1, alignment: .right))
        #expect(edit.applying(to: source) == "| A | B |\n| --- | --: |\n| one | two |\n")
    }

    @Test func pipeLessRowsRemainPipeLessForColumnMoves() throws {
        let source = "A | B | C\n---|---|---\na | b | c\n"
        let edit = try proposal(source, .moveColumn(from: 2, to: 0))
        #expect(edit.applying(to: source)?.contains(" C|A | B ") == true)
    }

    @Test func reverseRowMovePreservesCRLFAndFinalNewline() throws {
        let source = "| A | B |\r\n|---|---|\r\n| one | two |\r\n| three | four |\r\n"
        let edit = try proposal(source, .moveRow(from: 2, to: 1))
        #expect(edit.applying(to: source) == "| A | B |\r\n|---|---|\r\n| three | four |\r\n| one | two |\r\n")
    }

    /// Regression: a file that does not end in a newline has a last record with
    /// no terminator.  Inserting a row after it used to glue the new line onto
    /// its content (`| one | two || x | y |`).  The missing final newline is a
    /// byte-fidelity concern handled by `DocumentIO` at save time, so the
    /// proposal only needs to separate the rows.
    @Test func insertRowAfterTerminatorLessLastRowDoesNotGlue() throws {
        let source = "| A | B |\n|---|---|\n| one | two |"
        let edit = try proposal(source, .insertRow(index: 2, cells: ["x", "y"]))
        #expect(edit.applying(to: source) == "| A | B |\n|---|---|\n| one | two |\n| x | y |\n")
    }

    /// Regression: moving the terminator-less last row into the middle used to
    /// glue it onto its new neighbour.
    @Test func moveRowWithTerminatorLessLastRowDoesNotGlue() throws {
        let source = "| A | B |\n|---|---|\n| one | two |\n| three | four |"
        let edit = try proposal(source, .moveRow(from: 2, to: 1))
        #expect(edit.applying(to: source) == "| A | B |\n|---|---|\n| three | four |\n| one | two |\n")
    }

    @Test func blockquoteTableKeepsQuotePrefix() throws {
        let source = "> | A | B |\n> |---|---|\n> | one | two |\n"
        let edit = try proposal(source, .setCell(row: 1, column: 1, text: "changed"))
        #expect(edit.applying(to: source)?.contains("> | one | changed |") == true)
    }

    @Test func invalidStructureOperationsReturnTypedFallbacks() {
        let source = "| A |\n|---|\n| one |\n"
        let lastColumn = TableEditing.propose(MarkdownParser.parse(source), operation: .deleteColumn(index: 0))
        #expect(lastColumn.fallback == .cannotDeleteLastColumn)
        let tooMany = TableEditing.propose(MarkdownParser.parse(source), operation: .insertRow(index: 1, cells: ["one", "two"]))
        #expect(tooMany.fallback == .unsupportedOperation)
        let invalid = TableEditing.propose(MarkdownParser.parse(source), operation: .setCell(row: 99, column: 0, text: "x"))
        #expect(invalid.fallback == .invalidRow)
    }
}
