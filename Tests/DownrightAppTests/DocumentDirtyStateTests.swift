import Foundation
import Testing
@testable import DownrightApp

@MainActor
@Suite(.serialized)
struct DocumentDirtyStateTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dirty-state-\(UUID().uuidString).md")
        try Data("# Original\n".utf8).write(to: url)
        return url
    }

    @Test func deletingAnAccidentalSpaceReturnsToCleanWithoutSaving() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = MarkdownDocument()
        try document.open(url)
        defer { document.close() }
        document.replace(NSRange(location: 2, length: 0), with: " ", actionName: "Typing")
        #expect(document.isDirty)
        document.replace(NSRange(location: 2, length: 1), with: "", actionName: "Delete")
        #expect(!document.isDirty)
        #expect(document.presentationState.phase == .neutral)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# Original\n")
    }

    @Test func undoAndRedoTrackTheSavedText() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = MarkdownDocument()
        try document.open(url)
        defer { document.close() }
        document.replace(NSRange(location: 2, length: 0), with: "new ", actionName: "Typing")
        document.undoManager.undo()
        #expect(!document.isDirty)
        document.undoManager.redo()
        #expect(document.isDirty)
        try document.save()
        document.undoManager.undo()
        #expect(document.isDirty)
        document.undoManager.redo()
        #expect(!document.isDirty)
    }

    @Test func UnicodeNormalizationIsAnActualSourceEdit() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = MarkdownDocument()
        try document.open(url)
        defer { document.close() }
        document.replace(NSRange(location: 0, length: document.storage.length), with: "é\n", actionName: "Replace")
        try document.save()
        #expect(document.replace(NSRange(location: 0, length: document.storage.length), with: "e\u{301}\n", actionName: "Replace"))
        #expect(document.isDirty)
        document.ensureParsedCurrent()
        #expect(document.parsed.length == 3)
        document.undoManager.undo()
        #expect(!document.isDirty)
    }

    @Test func returningToSavedTextDoesNotEraseAnExternalConflict() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = MarkdownDocument()
        try document.open(url)
        defer { document.close() }
        document.replace(NSRange(location: 2, length: 0), with: " ", actionName: "Typing")
        try Data("# Agent version\n".utf8).write(to: url, options: .atomic)
        #expect(throws: SaveError.self) { try document.save() }
        #expect(document.pendingConflict != nil)
        document.replace(NSRange(location: 2, length: 1), with: "", actionName: "Delete")
        #expect(!document.isDirty)
        #expect(document.pendingConflict != nil)
        #expect(document.presentationState.phase == .conflict)
        _ = document.saveIfNeeded()
        #expect(try String(contentsOf: url, encoding: .utf8) == "# Agent version\n")
    }

    @Test func keepingMineAfterUndoWritesTheBuffer() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = MarkdownDocument()
        try document.open(url)
        defer { document.close() }
        document.replace(NSRange(location: 2, length: 0), with: "local ", actionName: "Typing")
        try Data("# Agent version\n".utf8).write(to: url, options: .atomic)
        #expect(throws: SaveError.self) { try document.save() }
        document.undoManager.undo()
        try #require(!document.isDirty)
        try #require(document.pendingConflict != nil)

        try document.resolveConflictKeepingMine().get()

        #expect(try String(contentsOf: url, encoding: .utf8) == "# Original\n")
        #expect(document.pendingConflict == nil)
    }

    @Test func keepingMineRequiresReviewOfANewerExternalWrite() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = MarkdownDocument()
        try document.open(url)
        defer { document.close() }
        document.replace(NSRange(location: 2, length: 0), with: "local ", actionName: "Typing")
        try Data("# First external version\n".utf8).write(to: url, options: .atomic)
        #expect(throws: SaveError.self) { try document.save() }
        try #require(document.pendingConflict?.incomingText == "# First external version\n")
        try Data("# Second external version\n".utf8).write(to: url, options: .atomic)

        #expect(throws: SaveError.self) { try document.resolveConflictKeepingMine().get() }

        #expect(try String(contentsOf: url, encoding: .utf8) == "# Second external version\n")
        #expect(document.pendingConflict?.incomingText == "# Second external version\n")
        #expect(document.text == "# local Original\n")
        #expect(document.isDirty)
        guard document.pendingConflict?.incomingText == "# Second external version\n" else { return }
        try document.resolveConflictKeepingMine().get()
        #expect(try String(contentsOf: url, encoding: .utf8) == "# local Original\n")
    }
}
