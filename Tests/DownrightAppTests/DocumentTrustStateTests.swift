import AppKit
import Foundation
import MarkdownCore
import Testing
@testable import DownrightApp

@Suite("Document save trust and presentation state", .serialized)
struct DocumentTrustStateTests {
    @Test @MainActor
    func missingFileSaveFailsClosedUntilExplicitRecreation() throws {
        let fixture = try Fixture(text: "before\n")
        defer { fixture.remove() }
        let document = MarkdownDocument()
        try document.open(fixture.url)
        #expect(document.replace(
            NSRange(location: 0, length: document.storage.length),
            with: "after\n",
            actionName: "Replace"
        ))
        try FileManager.default.removeItem(at: fixture.url)

        let result = document.saveIfNeeded()
        guard case .failure(SaveError.fileMissing) = result else {
            Issue.record("a missing path must be an explicit save failure")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(document.isDirty)
        #expect(document.presentationState.phase == .saveFailed)

        guard case .success = document.recreateMissingFile() else {
            Issue.record("explicit recreation should write the retained buffer")
            return
        }
        #expect(try String(contentsOf: fixture.url, encoding: .utf8) == "after\n")
        #expect(!document.isDirty)
        #expect(document.presentationState.phase == .saved)
        document.close()
    }

    @Test @MainActor
    func unreadablePathIsNotOverwritten() throws {
        let fixture = try Fixture(text: "before\n")
        defer { fixture.remove() }
        let document = MarkdownDocument()
        try document.open(fixture.url)
        #expect(document.replace(
            NSRange(location: 0, length: document.storage.length),
            with: "after\n",
            actionName: "Panel action"
        ))
        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: false)

        let result = document.saveIfNeeded()
        guard case .failure(SaveError.fileUnreadable) = result else {
            Issue.record("an unreadable existing path must fail closed")
            return
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: fixture.url.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(document.isDirty)
        document.close()
    }

    @Test @MainActor
    func taskToggleImmediateSaveNeverRecreatesADeletedFile() throws {
        let fixture = try Fixture(text: "- [ ] trust the save boundary\n")
        defer { fixture.remove() }
        let document = MarkdownDocument()
        try document.open(fixture.url)
        try FileManager.default.removeItem(at: fixture.url)

        document.toggleTask(atMarkOffset: 2)

        #expect(document.text == "- [x] trust the save boundary\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(document.isDirty)
        #expect(document.presentationState.phase == .saveFailed)
        document.close()
    }

    @Test @MainActor
    func conflictAndMutationProvenanceHaveDistinctStates() throws {
        let fixture = try Fixture(text: "one\n")
        defer { fixture.remove() }
        let document = MarkdownDocument()
        try document.open(fixture.url)
        #expect(document.replace(
            NSRange(location: 0, length: document.storage.length),
            with: "mine\n",
            actionName: "Paste"
        ))
        #expect(document.presentationState.phase == .edited)
        #expect(document.presentationState.provenance == "Paste")

        try Data("theirs\n".utf8).write(to: fixture.url, options: .atomic)
        let result = document.saveIfNeeded()
        guard case .failure(SaveError.blockedByExternalConflict) = result else {
            Issue.record("a newer disk version must become a conflict")
            return
        }
        #expect(document.presentationState.phase == .conflict)
        #expect(try String(contentsOf: fixture.url, encoding: .utf8) == "theirs\n")
        document.close()
    }

    @Test @MainActor
    func explicitKeepMineResolvesAndWritesARealConflict() throws {
        let fixture = try Fixture(text: "before\n")
        defer { fixture.remove() }
        let document = MarkdownDocument()
        try document.open(fixture.url)
        #expect(document.replace(
            NSRange(location: 0, length: document.storage.length),
            with: "mine\n", actionName: "Replace"
        ))
        try Data("theirs\n".utf8).write(to: fixture.url, options: .atomic)
        guard case .failure(SaveError.blockedByExternalConflict) = document.saveIfNeeded() else {
            Issue.record("the initial save must surface a conflict")
            return
        }

        guard case .success = document.resolveConflictKeepingMine() else {
            Issue.record("Keep Mine must be an explicit permitted overwrite")
            return
        }
        #expect(try Data(contentsOf: fixture.url) == Data("mine\n".utf8))
        #expect(!document.isDirty)
        #expect(document.pendingConflict == nil)
        document.close()
    }

    @Test @MainActor
    func atomicReplacementAtCommitBoundaryIsRestoredAndBecomesConflict() throws {
        let fixture = try Fixture(text: "before\n")
        defer { fixture.remove() }
        let document = MarkdownDocument()
        try document.open(fixture.url)
        #expect(document.replace(
            NSRange(location: 0, length: document.storage.length),
            with: "mine\n", actionName: "Paste"
        ))
        document.beforeSaveCommitForTesting = {
            try! Data("external-at-boundary\n".utf8).write(to: fixture.url, options: .atomic)
        }

        guard case .failure(SaveError.blockedByExternalConflict) = document.saveIfNeeded() else {
            Issue.record("a replacement at the exact commit boundary must fail closed")
            return
        }
        #expect(try Data(contentsOf: fixture.url) == Data("external-at-boundary\n".utf8))
        #expect(document.isDirty)
        document.close()
    }

    @Test @MainActor
    func deletionAtCommitBoundaryNeverRecreatesThePath() throws {
        let fixture = try Fixture(text: "before\n")
        defer { fixture.remove() }
        let document = MarkdownDocument()
        try document.open(fixture.url)
        #expect(document.replace(
            NSRange(location: 0, length: document.storage.length),
            with: "mine\n", actionName: "Replace"
        ))
        document.beforeSaveCommitForTesting = { try! FileManager.default.removeItem(at: fixture.url) }

        guard case .failure = document.saveIfNeeded() else {
            Issue.record("a concurrent deletion must fail")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(document.isDirty)
        document.close()
    }

    @Test @MainActor
    func recreateChoiceDoesNotClobberAFileThatReappeared() throws {
        let fixture = try Fixture(text: "before\n")
        defer { fixture.remove() }
        let document = MarkdownDocument()
        try document.open(fixture.url)
        #expect(document.replace(
            NSRange(location: 0, length: document.storage.length),
            with: "mine\n", actionName: "Replace"
        ))
        try FileManager.default.removeItem(at: fixture.url)
        guard case .failure(SaveError.fileMissing) = document.saveIfNeeded() else {
            Issue.record("missing file recovery must be active")
            return
        }
        try Data("restored-by-someone-else\n".utf8).write(to: fixture.url)

        guard case .failure(SaveError.blockedByExternalConflict) = document.recreateMissingFile() else {
            Issue.record("Recreate must reconcile a readable file that appeared after the alert")
            return
        }
        #expect(try Data(contentsOf: fixture.url) == Data("restored-by-someone-else\n".utf8))
        document.close()
    }

    @Test @MainActor
    func discardedEditsCannotReturnOnTheNextKeystroke() throws {
        let fixture = try Fixture(text: "saved\n")
        defer { fixture.remove() }
        let document = MarkdownDocument()
        try document.open(fixture.url)
        #expect(document.replace(
            NSRange(location: 0, length: document.storage.length),
            with: "discard-me\n", actionName: "Paste"
        ))
        document.discardUnsavedChanges()
        #expect(document.text == "saved\n")
        #expect(!document.isDirty)
        #expect(document.replace(
            NSRange(location: document.storage.length, length: 0),
            with: "new\n", actionName: "Typing"
        ))
        try document.save()
        #expect(try Data(contentsOf: fixture.url) == Data("saved\nnew\n".utf8))
        document.close()
    }

    /// §6.4: indent/outdent renumber ordered lists automatically, and the
    /// renumbering lands in the SAME undo group as the indentation — one ⌘Z
    /// restores the original text exactly.
    @Test @MainActor
    func outdentingAnOrderedListRenumbersInOneUndoGroup() throws {
        let fixture = try Fixture(text: "1. one\n   1. child\n2. two\n")
        defer { fixture.remove() }
        let document = MarkdownDocument()
        try document.open(fixture.url)

        // Outdent the nested item: the raw edit only removes its indent.
        document.ensureParsedCurrent()
        let line = (document.text as NSString).lineRange(for: NSRange(location: 7, length: 0))
        let edits = ListEditing.indent(document.parsed, lineRange: line, outdent: true)
        #expect(!edits.isEmpty)
        document.apply(edits, actionName: "Outdent", tidyRules: [.orderedListNumbers])

        #expect(document.text == "1. one\n2. child\n3. two\n",
                "the outdented list is renumbered automatically")

        // One undo step removes the renumber and the indent together.
        document.undoManager.undo()
        #expect(document.text == "1. one\n   1. child\n2. two\n")
        document.close()
    }

    /// The Discard composition, end to end: whatever implicit save work was
    /// already queued when the user pressed Discard must find a clean buffer
    /// afterwards and leave the declined bytes off disk.
    @Test @MainActor
    func lateImplicitSaveAfterDiscardWritesNothing() throws {
        let fixture = try Fixture(text: "on disk\n")
        defer { fixture.remove() }
        let document = MarkdownDocument()
        try document.open(fixture.url)
        #expect(document.replace(
            NSRange(location: 0, length: document.storage.length),
            with: "declined\n", actionName: "Paste"
        ))
        let diskBefore = try Data(contentsOf: fixture.url)

        // The alert handler's action for "Discard Changes".
        document.discardUnsavedChanges()
        #expect(!document.isDirty)

        guard case .success = document.saveIfNeeded() else {
            Issue.record("a discarded buffer must read as clean to implicit saves")
            return
        }
        #expect(try Data(contentsOf: fixture.url) == diskBefore,
                "the declined edits must not reach disk through any later save")
        document.close()
    }

    @Test @MainActor
    func byteOnlyExternalRewriteUpdatesFidelityBeforeSaving() throws {
        let fixture = try Fixture(text: "one\ntwo\n")
        defer { fixture.remove() }
        let document = MarkdownDocument()
        try document.open(fixture.url)
        let bomCRLF = Data([0xEF, 0xBB, 0xBF]) + Data("one\r\ntwo\r\n".utf8)
        try bomCRLF.write(to: fixture.url, options: .atomic)
        #expect(document.replace(
            NSRange(location: 0, length: 3), with: "ONE", actionName: "Replace"
        ))

        guard case .success = document.saveIfNeeded() else {
            Issue.record("a byte-only disk generation should reconcile without a content conflict")
            return
        }
        #expect(try Data(contentsOf: fixture.url) == Data([0xEF, 0xBB, 0xBF]) + Data("ONE\r\ntwo\r\n".utf8))
        document.close()
    }

    @Test @MainActor
    func removingFinalNewlineIsARealUserEdit() throws {
        let fixture = try Fixture(text: "body\n")
        defer { fixture.remove() }
        let document = MarkdownDocument()
        try document.open(fixture.url)
        #expect(document.replace(NSRange(location: 4, length: 1), with: "", actionName: "Delete"))
        try document.save()
        #expect(try Data(contentsOf: fixture.url) == Data("body".utf8))
        document.close()
    }

    @Test @MainActor
    func identicalRestoreClearsTheMissingFilePresentation() async throws {
        let fixture = try Fixture(text: "same\n")
        defer { fixture.remove() }
        let document = MarkdownDocument()
        try document.open(fixture.url)
        document.handleWatchEvent(.removed)
        #expect(document.presentationState.phase == .changedOnDisk)
        #expect(document.presentationState.detail == "File missing")

        document.handleWatchEvent(.restored)
        document.flushPendingExternalWrite()
        for _ in 0..<100 where document.presentationState.phase != .neutral {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(document.presentationState == .neutral)
        document.close()
    }

    @Test @MainActor
    func parsingAndOtherNonMutatingWorkNeverMarksDirty() throws {
        let fixture = try Fixture(text: "# Heading\n\nBody.\n")
        defer { fixture.remove() }
        let document = MarkdownDocument()
        try document.open(fixture.url)
        document.ensureParsedCurrent()
        document.markChangesReviewed()
        _ = document.restoredOffset()
        #expect(!document.isDirty)
        #expect(document.presentationState == .neutral)
        document.close()
    }

    @Test @MainActor
    func cleanExternalRewriteParsesAsynchronouslyAndRestoresAfterCommit() async throws {
        let document = MarkdownDocument()
        let original = "# One\n\nBody.\n"
        let incoming = "# One\n\n" + String(repeating: "A longer external paragraph.\n\n", count: 2_000)
        document.adopt(text: original, displayURL: nil)
        var incomingCommits = 0
        document.onReparse = { parsed, _ in
            if parsed.text == incoming { incomingCommits += 1 }
        }

        document.applyExternalText(
            incoming,
            hunks: TextDiff.hunks(old: original, new: incoming)
        )
        #expect(document.text == incoming)
        #expect(document.parsed.text != incoming, "the main actor must not synchronously parse a wholesale rewrite")

        for _ in 0..<200 where document.parsed.text != incoming {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(document.parsed.text == incoming)
        #expect(incomingCommits == 1)
        document.close()
    }

    @Test @MainActor
    func localEditDuringExternalParseOwnsTheLatestRevision() async throws {
        let document = MarkdownDocument()
        let original = "# One\n\nBody.\n"
        let incoming = "# External\n\nBody.\n"
        document.adopt(text: original, displayURL: nil)
        document.applyExternalText(
            incoming,
            hunks: TextDiff.hunks(old: original, new: incoming)
        )
        #expect(document.replace(
            NSRange(location: document.storage.length, length: 0),
            with: "Local tail.\n",
            actionName: "Paste"
        ))

        for _ in 0..<200 where document.parsed.text != document.text {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(document.parsed.text == document.text)
        #expect(document.text.hasSuffix("Local tail.\n"))
        #expect(document.isDirty)
        #expect(document.presentationState.provenance == "Paste")
        document.close()
    }
}

private struct Fixture {
    let root: URL
    let url: URL

    init(text: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("downright-document-trust-\(UUID().uuidString)", isDirectory: true)
        url = root.appendingPathComponent("note.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
