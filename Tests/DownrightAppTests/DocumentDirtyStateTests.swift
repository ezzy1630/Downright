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
}
