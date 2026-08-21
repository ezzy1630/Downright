import AppKit
import Foundation
import MarkdownCore
import Testing
@testable import DownrightApp

/// The save boundary must never write a buffer the user declined to keep, and
/// implicit saves must stop the moment the document (or the user's consent)
/// ends.  These tests pin that boundary at both layers: the document refuses
/// writes after close(), and the window's occlusion path is part of the
/// autosave feature rather than an unconditional writer.
@Suite("Autosave and close lifetime", .serialized)
struct AutosaveLifecycleTests {
    @Test @MainActor
    func closedDocumentRefusesImplicitAndExplicitSaves() throws {
        let fixture = try Fixture(text: "before\n")
        defer { fixture.remove() }
        let document = MarkdownDocument()
        try document.open(fixture.url)
        #expect(document.replace(
            NSRange(location: 0, length: document.storage.length),
            with: "after\n",
            actionName: "Replace"
        ))
        document.close()

        // A straggler implicit save (queued autosave work, occlusion during
        // teardown) must be a silent no-op, not a resurrection of the buffer.
        guard case .success = document.saveIfNeeded() else {
            Issue.record("saving a closed document must not surface an error")
            return
        }
        #expect(try String(contentsOf: fixture.url, encoding: .utf8) == "before\n")

        // Even a direct save call finds no owner to consent to the write.
        try document.save()
        #expect(try String(contentsOf: fixture.url, encoding: .utf8) == "before\n")
    }

    @Test @MainActor
    func occlusionSaveBelongsToTheAutosaveSetting() throws {
        let fixture = try Fixture(text: "before\n")
        defer { fixture.remove() }
        let original = Preferences.shared.values.autosaveEnabled
        defer { Preferences.shared.update { $0.autosaveEnabled = original } }

        let controller = DocumentWindowController()
        defer { controller.close() }
        try controller.open(fixture.url, mode: .live)
        #expect(controller.markdownDocument.replace(
            NSRange(location: 0, length: controller.markdownDocument.storage.length),
            with: "after\n",
            actionName: "Replace"
        ))

        // Default (autosave off): covering or miniaturizing the window must
        // not commit the buffer — an agent may be editing the same file.
        Preferences.shared.update { $0.autosaveEnabled = false }
        controller.windowDidChangeOcclusionState(Notification(
            name: NSWindow.didChangeOcclusionStateNotification, object: controller.window
        ))
        #expect(try String(contentsOf: fixture.url, encoding: .utf8) == "before\n")
        #expect(controller.markdownDocument.isDirty)

        // With autosave enabled the occlusion save still works.
        Preferences.shared.update { $0.autosaveEnabled = true }
        controller.windowDidChangeOcclusionState(Notification(
            name: NSWindow.didChangeOcclusionStateNotification, object: controller.window
        ))
        #expect(try String(contentsOf: fixture.url, encoding: .utf8) == "after\n")
        #expect(!controller.markdownDocument.isDirty)
    }

    @Test @MainActor
    func pathTokenActionsStayInertForMissingPaths() throws {
        let fixture = try Fixture(text: "see `src/gone.ts:42` and [link](notes.md)\n")
        defer { fixture.remove() }
        let controller = DocumentWindowController()
        defer { controller.close() }
        try controller.open(fixture.url, mode: .live)

        // The documented contract (§ Workspace and path resolution): missing
        // paths are clear but never run a command — no editor launch, no
        // Finder reveal, from activation or from the context menu alike.
        let missing = PathToken(rawPath: "src/gone.ts", line: 42)
        #expect(controller.pathResolver?.resolve(missing).exists == false)
        #expect(!controller.openPathTokenInEditor(missing))
        #expect(!controller.revealPathTokenInFinder(missing))
    }
}

private struct Fixture {
    let root: URL
    let url: URL

    init(text: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("downright-autosave-lifetime-\(UUID().uuidString)", isDirectory: true)
        url = root.appendingPathComponent("note.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
