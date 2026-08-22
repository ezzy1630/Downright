import Foundation
import AppKit
import Testing
import MarkdownCore
import MarkdownRender
@testable import DownrightApp

// Tests for the app layer: history, reading position, change marks, find, path
// resolution, key bindings, and export.  Everything here is headless — the
// window and text surface are exercised by hand, but the logic that has to be
// right when an agent rewrites a file under you is testable and tested.
//
// Serialised because several of these exercise process-wide singletons
// (`SnapshotStore.shared`, `KeybindingStore.shared`) that would otherwise race.

@Suite(.serialized)
struct AppLayerTests {

    // MARK: - Scroll anchoring (§8.1, §8.2)

    @Test func anchorSurvivesInsertionAboveIt() throws {
        let before = """
        # Title

        Intro paragraph.

        ## Second section

        The paragraph the reader is looking at.

        ## Third section

        Trailing content.
        """
        let after = """
        # Title

        Intro paragraph.

        ## A section the agent inserted

        Several new paragraphs of content that did not exist before.

        More new content, pushing everything below it down the file.

        ## Second section

        The paragraph the reader is looking at.

        ## Third section

        Trailing content.
        """

        let oldDocument = MarkdownParser.parse(before)
        let newDocument = MarkdownParser.parse(after)

        let secondSection = try #require(oldDocument.headings.first { $0.title == "Second section" })
        let readingOffset = secondSection.sectionRange.location + secondSection.sectionRange.length / 2

        let anchor = ScrollAnchoring.anchor(for: readingOffset, in: oldDocument)
        let restored = ScrollAnchoring.offset(for: anchor, in: newDocument)

        let newSecond = try #require(newDocument.headings.first { $0.title == "Second section" })
        #expect(
            newSecond.sectionRange.contains(offset: restored),
            "reading position must land back inside the same section, not at the same byte offset"
        )
    }

    @Test func anchorFallsBackWhenHeadingDisappears() {
        let document = MarkdownParser.parse("# Only heading\n\nBody.\n")
        let anchor = ScrollAnchor(headingSlug: "long-gone", headingIndex: 4, fractionThroughSection: 0.5)
        let offset = ScrollAnchoring.offset(for: anchor, in: document)
        #expect(offset >= 0 && offset <= document.length)
    }

    // MARK: - Change marks (§8.1)

    @Test func changeMarksShiftWithEditsAndDropWhenOverwritten() {
        let tracker = ChangeTracker()
        tracker.apply(hunks: [
            ChangeHunk(kind: .modified, newRange: NSRange(location: 100, length: 20), oldRange: NSRange(location: 100, length: 18)),
            ChangeHunk(kind: .inserted, newRange: NSRange(location: 300, length: 40), oldRange: NSRange(location: 300, length: 0)),
        ])
        #expect(tracker.count == 2)

        // An edit before both marks shifts both.
        tracker.adjust(forEditIn: NSRange(location: 10, length: 0), delta: 5)
        #expect(tracker.marks[0].range.location == 105)
        #expect(tracker.marks[1].range.location == 305)

        // An edit overlapping a mark drops it: once you have rewritten the text
        // yourself, calling it "changed by the agent" would be a lie.
        tracker.adjust(forEditIn: NSRange(location: 106, length: 4), delta: 0)
        #expect(tracker.count == 1)
        #expect(tracker.marks[0].range.location == 305)
    }

    @Test func changeNavigationWrapsAround() {
        let tracker = ChangeTracker()
        tracker.apply(hunks: [
            ChangeHunk(kind: .modified, newRange: NSRange(location: 50, length: 10), oldRange: NSRange(location: 50, length: 10)),
            ChangeHunk(kind: .modified, newRange: NSRange(location: 200, length: 10), oldRange: NSRange(location: 200, length: 10)),
        ])
        #expect(tracker.next(after: 0)?.range.location == 50)
        #expect(tracker.next(after: 100)?.range.location == 200)
        #expect(tracker.next(after: 900)?.range.location == 50, "wraps to the first mark")
        #expect(tracker.previous(before: 100)?.range.location == 50)
        #expect(tracker.previous(before: 0)?.range.location == 200, "wraps to the last mark")
    }

    @Test func visitedMarksStopDrawing() {
        let tracker = ChangeTracker()
        tracker.apply(hunks: [
            ChangeHunk(kind: .inserted, newRange: NSRange(location: 0, length: 5), oldRange: NSRange(location: 0, length: 0)),
        ])
        let id = tracker.marks[0].id
        #expect(tracker.visibleMarks.count == 1)
        tracker.markVisited(id)
        #expect(tracker.visibleMarks.isEmpty)
        #expect(tracker.count == 1, "the mark still exists for navigation, it just stops drawing")
    }

    // MARK: - Snapshot store (§8.3)

    @Test func snapshotStoreDeduplicatesAndRestores() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(historyDirectory: root.appendingPathComponent("history"))
        let url = root.appendingPathComponent("document.md")

        let first = "# One\n\nBody.\n"
        let second = "# One\n\nBody, revised.\n"

        #expect(store.record(first, for: url, kind: .baseline) != nil)
        #expect(store.record(first, for: url, kind: .external) == nil, "identical content must not create a version")
        #expect(store.record(second, for: url, kind: .external) != nil)

        // The duplicate assertion above runs before the first async index
        // write can be relied on.  Drain the queue explicitly before reading.
        await store.waitForPendingWrites()

        let versions = store.versions(for: url)
        #expect(versions.count == 2)
        #expect(store.text(for: versions[0]) == first)
        #expect(store.text(for: versions[1]) == second)
    }

    private func snapshotIndexFile(for url: URL, historyDirectory: URL) -> URL {
        historyDirectory
            .appendingPathComponent("index", isDirectory: true)
            .appendingPathComponent(SnapshotStore.documentKey(for: url) + ".json")
    }

    private func writeSnapshotIndex(path: String, age: TimeInterval, to file: URL) throws {
        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-age))
        let encodedPath = try #require(String(data: JSONEncoder().encode(path), encoding: .utf8))
        let json = """
        {"path":\(encodedPath),"versions":[{"hash":"\(String(repeating: "a", count: 64))",\
        "date":"\(stamp)","byteCount":12,"kind":"external"}]}
        """
        AppPaths.ensure(file.deletingLastPathComponent())
        try Data(json.utf8).write(to: file, options: .atomic)
    }

    private func ageSnapshotIndex(_ file: URL, by age: TimeInterval) throws {
        let data = try Data(contentsOf: file)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var versions = try #require(json["versions"] as? [[String: Any]])
        versions[versions.count - 1]["date"] = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-age)
        )
        json["versions"] = versions
        try JSONSerialization.data(withJSONObject: json).write(to: file, options: .atomic)
    }

    private func runSnapshotPrune(_ store: SnapshotStore) async {
        await store.pruneOneGenerationForTesting()
    }

    @Test func pruneKeepsNewestHistoryForMissingDocument() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-prune-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let historyDirectory = root.appendingPathComponent("history", isDirectory: true)
        let store = SnapshotStore(historyDirectory: historyDirectory)
        let url = root.appendingPathComponent("gone.md")
        let file = snapshotIndexFile(for: url, historyDirectory: historyDirectory)

        let text = "gone but cached\n"
        #expect(store.record(text, for: url, kind: .baseline) != nil)
        await store.waitForPendingWrites()
        try ageSnapshotIndex(file, by: 90 * 24 * 60 * 60)
        await runSnapshotPrune(store)
        await runSnapshotPrune(store)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(store.versions(for: url).count == 1, "the newest version survives age pruning")
        #expect(store.text(for: store.versions(for: url)[0]) == text)
    }

    @Test func pruneKeepsObjectsWhenIndexDirectoryCannotBeListed() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-prune-index-directory-\(UUID().uuidString)", isDirectory: true)
        let historyDirectory = root.appendingPathComponent("history", isDirectory: true)
        let indexDirectory = historyDirectory.appendingPathComponent("index", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: indexDirectory.path)
            try? FileManager.default.removeItem(at: root)
        }
        let store = SnapshotStore(historyDirectory: historyDirectory)
        let document = root.appendingPathComponent("document.md")
        let text = "must survive an unreadable index directory\n"
        let record = try #require(store.record(text, for: document, kind: .baseline))
        await store.waitForPendingWrites()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: indexDirectory.path)

        await runSnapshotPrune(store)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: indexDirectory.path)
        #expect(store.content(for: record) == .text(text))
    }

    @Test func pruneKeepsObjectsWhenAnyIndexIsCorrupt() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-prune-corrupt-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let historyDirectory = root.appendingPathComponent("history", isDirectory: true)
        let store = SnapshotStore(historyDirectory: historyDirectory)
        let document = root.appendingPathComponent("document.md")
        let text = "must survive a corrupt index\n"
        let record = try #require(store.record(text, for: document, kind: .baseline))
        await store.waitForPendingWrites()
        let index = snapshotIndexFile(for: document, historyDirectory: historyDirectory)
        try Data("not json".utf8).write(to: index, options: .atomic)

        await runSnapshotPrune(store)

        #expect(store.content(for: record) == .text(text))
    }

    @Test func pruneKeepsObjectsWhenAnyIndexFileIsUnreadable() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-prune-unreadable-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let historyDirectory = root.appendingPathComponent("history", isDirectory: true)
        let store = SnapshotStore(historyDirectory: historyDirectory)
        let document = root.appendingPathComponent("document.md")
        let text = "must survive an unreadable index file\n"
        let record = try #require(store.record(text, for: document, kind: .baseline))
        await store.waitForPendingWrites()
        let index = snapshotIndexFile(for: document, historyDirectory: historyDirectory)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: index.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path) }

        await runSnapshotPrune(store)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
        #expect(store.content(for: record) == .text(text))
    }

    /// Regression: a present-but-undecodable index used to be treated as an
    /// empty one, so the next record overwrote it with a single-entry index
    /// and the following prune garbage-collected every object the old index
    /// referenced — one corrupt file became permanent history loss.
    @Test func recordNeverOverwritesAnUnreadableIndex() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-record-unreadable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let historyDirectory = root.appendingPathComponent("history", isDirectory: true)
        let store = SnapshotStore(historyDirectory: historyDirectory)
        let document = root.appendingPathComponent("document.md")
        let file = snapshotIndexFile(for: document, historyDirectory: historyDirectory)

        let first = "first version\n"
        #expect(store.record(first, for: document, kind: .baseline) != nil)
        await store.waitForPendingWrites()
        let versionsBefore = store.versions(for: document)
        #expect(versionsBefore.count == 1)

        try Data("not json".utf8).write(to: file, options: .atomic)
        let corruptedBytes = try Data(contentsOf: file)

        // Recording after corruption must not replace the unreadable index.
        #expect(store.record("second version\n", for: document, kind: .external) != nil)
        await store.waitForPendingWrites()
        #expect(try Data(contentsOf: file) == corruptedBytes,
                "the undecodable index file must be left exactly as it was")
        #expect(store.content(forHash: versionsBefore[0].hash) == .text(first),
                "the recorded object must survive a prune that fails closed")
    }

    /// The `forget` sweep shares prune's rule: with an undecodable index in
    /// play, reference knowledge is incomplete and nothing may be deleted.
    @Test func forgetDoesNotSweepObjectsBehindAnUnreadableIndex() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-forget-unreadable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let historyDirectory = root.appendingPathComponent("history", isDirectory: true)
        let store = SnapshotStore(historyDirectory: historyDirectory)

        let kept = root.appendingPathComponent("kept.md")
        let keptText = "kept behind a corrupt index\n"
        #expect(store.record(keptText, for: kept, kind: .baseline) != nil)
        await store.waitForPendingWrites()

        let forgotten = root.appendingPathComponent("forgotten.md")
        #expect(store.record("forgotten\n", for: forgotten, kind: .baseline) != nil)
        await store.waitForPendingWrites()

        // Corrupt the *kept* document's index, then forget the other one.
        let keptIndex = snapshotIndexFile(for: kept, historyDirectory: historyDirectory)
        try Data("not json".utf8).write(to: keptIndex, options: .atomic)

        store.forget(forgotten)
        await store.waitForPendingWrites()

        let keptVersions = store.versions(for: kept)
        #expect(keptVersions.isEmpty, "the corrupt index reads as no versions")
        #expect(store.content(forHash: SnapshotStore.hash(keptText)) == .text(keptText),
                "its objects must not be swept while its index is unreadable")
    }

    @Test func pruneKeepsOldHistoryForLiveDocument() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-prune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let historyDirectory = root.appendingPathComponent("history", isDirectory: true)
        let store = SnapshotStore(historyDirectory: historyDirectory)
        let url = root.appendingPathComponent("live.md")
        try Data("# Live\n".utf8).write(to: url)
        let file = snapshotIndexFile(for: url, historyDirectory: historyDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        try writeSnapshotIndex(path: url.path, age: 90 * 24 * 60 * 60, to: file)
        await runSnapshotPrune(store)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func pruneDoesNotRewriteUnchangedIndex() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-prune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let historyDirectory = root.appendingPathComponent("history", isDirectory: true)
        let store = SnapshotStore(historyDirectory: historyDirectory)
        let url = root.appendingPathComponent("stable.md")
        try Data("# Stable\n".utf8).write(to: url)
        let file = snapshotIndexFile(for: url, historyDirectory: historyDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        store.record("# Stable\n", for: url, kind: .baseline)
        await store.waitForPendingWrites()
        let mark = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: mark], ofItemAtPath: file.path)
        await runSnapshotPrune(store)

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.modificationDate] as? Date == mark)
    }

    @Test func readingStatePersistsWhenDocumentIsMissing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let store = DocumentStateStore(supportDirectory: support)
        let document = root.appendingPathComponent("missing.md")
        let stateFile = support.appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent(SnapshotStore.documentKey(for: document) + ".json")
        var state = DocumentState(path: document.path)
        state.lastOpened = .distantPast
        state.selectionLocation = 42
        store.save(state, for: document)

        #expect(FileManager.default.fileExists(atPath: stateFile.path))
        let reopenedStore = DocumentStateStore(supportDirectory: support)
        #expect(reopenedStore.state(for: document).selectionLocation == 42)
    }

    @Test func contentHashIsStable() {
        #expect(SnapshotStore.hash("abc") == SnapshotStore.hash("abc"))
        #expect(SnapshotStore.hash("abc") != SnapshotStore.hash("abd"))
        #expect(SnapshotStore.hash("").count == 64, "sha256 hex")
    }

    @Test func documentStateKeepsSelectionAndSplitView() throws {
        var state = DocumentState(path: "/tmp/note.md")
        state.selectionLocation = 42
        state.selectionLength = 7
        state.splitViewEnabled = true
        state.mode = .source
        state.zoomLevel = .skeleton
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(DocumentState.self, from: data)
        #expect(decoded.selectionLocation == 42)
        #expect(decoded.selectionLength == 7)
        #expect(decoded.splitViewEnabled)
        #expect(decoded.mode == .live, "transient Source Focus must not restore")
        #expect(decoded.zoomLevel == .everything, "editable documents must reopen without hidden prose")
    }

    @Test @MainActor
    func failedSaveReturnsErrorAndPreservesBuffer() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-save-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("note.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("before\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: root) }

        let document = MarkdownDocument()
        try document.open(url)
        #expect(document.replace(
            NSRange(location: 0, length: document.storage.length),
            with: "after\n",
            actionName: nil
        ))

        var failureCount = 0
        document.onSaveFailure = { _ in failureCount += 1 }
        try FileManager.default.removeItem(at: root)

        let result = document.saveIfNeeded()
        guard case .failure = result else {
            Issue.record("saveIfNeeded must report a failed disk write")
            return
        }
        #expect(document.isDirty)
        #expect(document.text == "after\n")
        #expect(failureCount == 1)

        document.changes.apply(hunks: [
            ChangeHunk(
                kind: .modified,
                newRange: NSRange(location: 0, length: 5),
                oldRange: NSRange(location: 0, length: 6)
            ),
        ])
        let conflictResult = document.resolveConflictKeepingMine()
        guard case .failure = conflictResult else {
            Issue.record("conflict resolution must report a failed save")
            return
        }
        #expect(document.changes.count == 1)
        #expect(failureCount == 2)
        document.close()
    }

    @MainActor
    @Test
    func changeMarksDoNotLeakAcrossInPlaceReopen() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-hop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstURL = root.appendingPathComponent("first.md")
        let secondURL = root.appendingPathComponent("second.md")
        try Data("# First\n\nAlpha.\n".utf8).write(to: firstURL)
        try Data("# Second\n\nBeta.\n".utf8).write(to: secondURL)

        let document = MarkdownDocument()
        try document.open(firstURL)
        document.changes.apply(hunks: [
            ChangeHunk(kind: .modified,
                       newRange: NSRange(location: 0, length: 5),
                       oldRange: NSRange(location: 0, length: 5)),
        ])
        #expect(document.changes.count == 1)

        // An in-place hop reuses the same document; stale marks must not
        // decorate the next file.
        try document.open(secondURL)
        #expect(document.changes.isEmpty, "change marks leaked across an in-place reopen")
        document.close()
    }

    @Test
    func preferencesValuesRoundTripEverySetting() throws {
        var values = Preferences.Values()
        values.themeName = "Light"
        values.darkThemeName = "Dark"
        values.followsSystemAppearance = false
        values.typography.preset = .working
        values.typography.bodySize = 18
        values.typography.scaleRatio = 1.333
        values.typography.lineHeightMultiple = 1.7
        values.typography.measureCharacters = 72
        values.typography.monoFamily = "Menlo"
        values.typography.monoSizeAdjust = 1
        values.typography.monoLigatures = true
        values.typography.opticalMargins = false
        values.typography.mathScale = 1.2
        values.textSizeAdjustment = 2
        values.typographicSubstitution = true
        values.showInvisibles = true
        values.typewriterScrolling = true
        values.focusMode = true
        values.codeBlockCollapseThreshold = 40
        values.defaultMode = .source
        values.restoreSession = false
        values.externalEditor = .vscode
        values.resolvePathTokens = false
        values.siblingScanDirectories = ["custom"]
        values.historyMaximumDays = 90
        values.historyMaximumMegabytes = 900
        values.watchFiles = false
        values.vimKeys = true
        values.revealMarkersAtAllCursors = true
        values.largeFileThresholdMegabytes = 20

        let data = try JSONEncoder().encode(values)
        let decoded = try JSONDecoder().decode(Preferences.Values.self, from: data)
        #expect(decoded == values)
    }

    @Test
    func legacyPreferencesRestoreSystemAppearanceFollowing() throws {
        let legacy = Data(#"{"followsSystemAppearance":false}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.Values.self, from: legacy)

        #expect(decoded.followsSystemAppearance)
    }

    @Test
    func choosingAThemeDoesNotChangeTheAppearanceMode() {
        var values = Preferences.Values()
        values.followsSystemAppearance = true

        values.selectTheme(named: "Solarized Light", for: .light)
        values.selectTheme(named: "Nord", for: .dark)

        #expect(values.themeName == "Solarized Light")
        #expect(values.darkThemeName == "Nord")
        #expect(values.followsSystemAppearance)
    }

    // MARK: - Find (§9.4)

    @Test func findLiteralRegexAndWholeWord() {
        let text = "alpha beta alphabet ALPHA"

        var query = FindQuery(); query.text = "alpha"
        #expect(FindEngine.matches(in: text, query: query).count == 3, "case-insensitive by default")

        query.caseSensitive = true
        #expect(FindEngine.matches(in: text, query: query).count == 2)

        query.wholeWord = true
        #expect(FindEngine.matches(in: text, query: query).count == 1, "alphabet must not match")

        var regex = FindQuery(); regex.text = "al(pha|beit)"; regex.isRegex = true
        #expect(FindEngine.matches(in: text, query: regex).count == 3)
    }

    @Test func findTreatsSpecialCharactersLiterallyWhenNotRegex() {
        var query = FindQuery(); query.text = "a.c"
        #expect(FindEngine.matches(in: "abc a.c", query: query).count == 1)
        query.isRegex = true
        #expect(FindEngine.matches(in: "abc a.c", query: query).count == 2)
    }

    @Test func halfTypedRegexReturnsNothingRatherThanThrowing() {
        var query = FindQuery(); query.text = "a("; query.isRegex = true
        #expect(FindEngine.matches(in: "aaa", query: query).isEmpty)
        #expect(!FindEngine.isValid(query))
    }

    @Test func regexReplacementExpandsCaptureGroups() throws {
        var query = FindQuery(); query.text = #"(\w+)@(\w+)"#; query.isRegex = true
        let text = "user@host"
        let match = try #require(FindEngine.matches(in: text, query: query).first)
        #expect(FindEngine.replacement(for: match, in: text, query: query, template: "$2/$1") == "host/user")
    }

    @Test func findSessionAdvancesAndWraps() {
        let session = FindSession()
        var query = FindQuery(); query.text = "x"
        session.update(query: query, in: "x--x--x", caret: 0)
        #expect(session.count == 3)
        #expect(session.statusText == "1 of 3")
        _ = session.advance(forward: true)
        #expect(session.statusText == "2 of 3")
        _ = session.advance(forward: true)
        _ = session.advance(forward: true)
        #expect(session.statusText == "1 of 3", "wraps")
    }

    // MARK: - Path resolution (§8.4)

    @Test func pathResolverDistinguishesPresentFromMissing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-paths-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("// real\n".utf8).write(to: source.appendingPathComponent("real.ts"))
        let documentURL = root.appendingPathComponent("PLAN.md")
        try Data("# Plan\n".utf8).write(to: documentURL)

        let resolver = PathResolver(documentURL: documentURL)
        #expect(resolver.resolve(PathToken(rawPath: "src/real.ts")).exists)
        #expect(resolver.resolve(PathToken(rawPath: "src/real.ts", line: 42)).exists)
        #expect(resolver.resolve(PathToken(rawPath: "src/real.ts", line: 42)).line == 42)
        #expect(
            !resolver.resolve(PathToken(rawPath: "src/auth/session.ts", line: 42)).exists,
            "a file the agent claims to have touched that isn't there must resolve as missing"
        )
    }

    /// "Open in your editor" never means "run it": execution-capable targets
    /// linked from a document must be classified so every open path reveals
    /// them in Finder instead of handing them to LaunchServices.
    @Test func executableTargetsAreClassifiedForRevealInsteadOfLaunch() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-exec-classify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func write(_ name: String, _ bytes: Data, permissions: Int? = nil) throws -> URL {
            let url = root.appendingPathComponent(name)
            try bytes.write(to: url)
            if let permissions {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path
                )
            }
            return url
        }

        // Application bundles and Terminal-run scripts execute on open.
        let bundle = root.appendingPathComponent("Evil.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        #expect(DocumentTypes.executesWhenOpened(bundle))
        #expect(try DocumentTypes.executesWhenOpened(
            write("run.tool", Data("#!/bin/sh\necho hi\n".utf8))
        ))
        // An executable bit with no extension at all is a raw binary/script.
        #expect(try DocumentTypes.executesWhenOpened(
            write("deploy", Data("#!/bin/sh\necho hi\n".utf8), permissions: 0o755)
        ))

        // Documents — including executable-bit scripts with a document-ish
        // extension, which open in an editor — do not execute.
        #expect(try !DocumentTypes.executesWhenOpened(write("notes.md", Data("# hi\n".utf8))))
        #expect(try !DocumentTypes.executesWhenOpened(
            write("build.sh", Data("#!/bin/sh\n".utf8), permissions: 0o755)
        ))
        #expect(try !DocumentTypes.executesWhenOpened(
            write("diagram.png", Data("\u{89}PNG".utf8))
        ))
        let folder = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(!DocumentTypes.executesWhenOpened(folder))
    }

    @Test @MainActor
    func pathResolverWarmsCacheAndReturnsOnMainQueue() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-path-warm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("ready\n".utf8).write(to: root.appendingPathComponent("ready.md"))

        let resolver = PathResolver(documentURL: root.appendingPathComponent("document.md"))
        #expect(resolver.cachedResolution(for: PathToken(rawPath: "ready.md")) == nil)
        await withCheckedContinuation { continuation in
            resolver.warm([
                PathToken(rawPath: "ready.md"),
                PathToken(rawPath: "ready.md", line: 9),
                PathToken(rawPath: "missing.md"),
            ]) {
                #expect(Thread.isMainThread)
                continuation.resume()
            }
        }

        #expect(resolver.resolve(PathToken(rawPath: "ready.md", line: 9)).exists)
        #expect(resolver.resolve(PathToken(rawPath: "ready.md", line: 9)).line == 9)
        #expect(!resolver.resolve(PathToken(rawPath: "missing.md")).exists)
        #expect(resolver.cachedResolution(for: PathToken(rawPath: "ready.md"))?.exists == true)

        try FileManager.default.removeItem(at: root.appendingPathComponent("ready.md"))
        await withCheckedContinuation { continuation in
            resolver.warm([PathToken(rawPath: "ready.md")]) { continuation.resume() }
        }
        #expect(
            resolver.cachedResolution(for: PathToken(rawPath: "ready.md"))?.exists == true,
            "a current-generation cache hit must not be restatted on every reparse"
        )
    }

    @Test @MainActor
    func newlyParsedPathTokenRemainsUncachedUntilBackgroundWarmCompletes() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-new-path-token-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = PathResolver(documentURL: root.appendingPathComponent("document.md"))
        let newToken = PathToken(rawPath: "generated.md")

        // This token represents one introduced by the new parse after an
        // external rewrite. Decoration must not synchronously stat it.
        #expect(resolver.cachedResolution(for: newToken) == nil)
        try Data("generated\n".utf8).write(to: root.appendingPathComponent(newToken.rawPath))
        await withCheckedContinuation { continuation in
            resolver.warm([newToken]) { continuation.resume() }
        }
        #expect(resolver.cachedResolution(for: newToken)?.exists == true)
    }

    @Test func gitRootDiscoveryStopsAtTheRepository() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-git-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("docs/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(
            PathResolver.findGitRoot(from: nested)?.standardizedFileURL.path
                == root.standardizedFileURL.resolvingSymlinksInPath().path
                || PathResolver.findGitRoot(from: nested)?.standardizedFileURL.path == root.standardizedFileURL.path
        )
    }

    /// An editor deep link carries the path inside a URL, so a directory named
    /// `Design #2` or `100%` has to survive the trip.  Unencoded, `#` and `?`
    /// truncate the path at a fragment or query boundary and the editor opens
    /// the wrong file; `%` and spaces can fail the parse outright, which drops
    /// the caller back to `NSWorkspace.open` and loses the line number.
    @Test func editorDeepLinksPercentEncodeAwkwardPaths() throws {
        for editor in [ExternalEditor.vscode, .cursor, .zed] {
            let scheme = editor == .vscode ? "vscode" : (editor == .cursor ? "cursor" : "zed")

            let plain = try #require(
                editor.url(for: URL(fileURLWithPath: "/src/auth/session.ts"), line: 42)
            )
            #expect(plain.absoluteString == "\(scheme)://file/src/auth/session.ts:42")

            for awkward in ["/notes/Design #2/plan.md", "/notes/why?/plan.md",
                            "/notes/100%/plan.md", "/notes/My Notes/plan.md"] {
                let url = try #require(
                    editor.url(for: URL(fileURLWithPath: awkward), line: 7),
                    "\(awkward) produced no URL, so the caller loses the line number"
                )
                #expect(url.fragment == nil, "\(awkward) leaked a fragment")
                #expect(url.query == nil, "\(awkward) leaked a query")
                #expect(url.path == "\(awkward):7", "\(awkward) did not round-trip")
                #expect(url.absoluteString.hasSuffix(":7"), "\(awkward) lost its line suffix")
            }
        }

        // Editors without a line-carrying scheme stay on the fallback path.
        #expect(ExternalEditor.xcode.url(for: URL(fileURLWithPath: "/a.md"), line: 1) == nil)
        #expect(ExternalEditor.systemDefault.url(for: URL(fileURLWithPath: "/a.md"), line: 1) == nil)

        // No line number means no suffix to misparse.
        let noLine = try #require(ExternalEditor.zed.url(for: URL(fileURLWithPath: "/a b.md"), line: nil))
        #expect(noLine.absoluteString == "zed://file/a%20b.md")
    }

    // MARK: - Key bindings (§7.2)

    @Test func keyBindingRoundTripsThroughItsStringForm() throws {
        for source in ["cmd+e", "cmd+shift+o", "opt+down", "space", "shift+space", "ctrl+opt+shift+cmd+k", "["] {
            let binding = try #require(KeyBinding(parsing: source), "failed to parse \(source)")
            #expect(KeyBinding(parsing: binding.serialized) == binding)
        }
    }

    /// Caps Lock and Fn are sticky state, not part of a chord.  A binding must
    /// compare equal to an event carrying them, or every shortcut silently dies
    /// when the user's caps lock is on (§7.2).
    @Test func keyBindingsIgnoreCapsLockAndFunctionFlags() {
        let binding = KeyBinding("s", .command)
        let withCapsLock = KeyBinding("s", [.command, .capsLock, .function])
        #expect(binding == withCapsLock)
        #expect(binding.hashValue == withCapsLock.hashValue)

        // The event-driven lookup must resolve ⌘S while Caps Lock is held.
        let store = KeybindingStore.shared
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: [.command, .capsLock],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "s", charactersIgnoringModifiers: "s",
            isARepeat: false, keyCode: 0
        )
        let resolved = event.flatMap { store.command(for: $0, scope: .live) }
        #expect(resolved == .save)
    }

    @Test func defaultBindingsMatchTheSpecTable() {
        let store = KeybindingStore.shared
        #expect(store.primaryBinding(for: .sourceMode) == KeyBinding("e", [.command, .shift]))
        #expect(store.primaryBinding(for: .find) == KeyBinding("f", .command))
        #expect(store.primaryBinding(for: .useSelectionForFind) == KeyBinding("e", .command))
        #expect(store.primaryBinding(for: .copyAsMarkdown) == KeyBinding("c", [.command, .option, .shift]))
        // ⌘0 is Actual Size on macOS, ⌘⇧V is Paste and Match Style, and ⌥↑/⌥↓
        // are moveParagraphBackward:/Forward: while a caret is in the document,
        // so these three moved off the chords the system already owns.
        #expect(store.primaryBinding(for: .versionTimeline) == KeyBinding("v", [.command, .option]))
        #expect(store.primaryBinding(for: .nextChange) == KeyBinding("down", [.option, .shift]))
        #expect(store.primaryBinding(for: .splitView) == KeyBinding("backslash", .command))
    }

    @Test func everyCommandHasATitleAndSomewhereToRun() {
        for command in Command.allCases {
            #expect(!command.title.isEmpty, "\(command.rawValue) has no title")
            #expect(!command.scopes.isEmpty, "\(command.rawValue) is dispatchable nowhere")
        }
    }

    @Test func bindingConflictsAreDetected() throws {
        let store = KeybindingStore.shared
        let binding = try #require(store.primaryBinding(for: .find))
        #expect(store.conflicts(for: binding, excluding: .findNext).contains(.find))
        #expect(!store.conflicts(for: binding, excluding: .find).contains(.find))
    }

    // MARK: - Jump history (§7.1)

    @Test func jumpHistoryBehavesLikeABrowser() {
        let history = JumpHistory()
        let from = JumpHistory.Entry(url: nil, offset: 0, label: "start")
        history.record(from: from, to: JumpHistory.Entry(url: nil, offset: 100, label: "a"))
        history.record(from: JumpHistory.Entry(url: nil, offset: 100, label: "a"),
                       to: JumpHistory.Entry(url: nil, offset: 200, label: "b"))

        #expect(history.canGoBack)
        #expect(!history.canGoForward)
        #expect(history.goBack()?.offset == 100)
        #expect(history.canGoForward)
        #expect(history.goForward()?.offset == 200)

        // A new jump truncates the forward stack.
        _ = history.goBack()
        history.record(from: JumpHistory.Entry(url: nil, offset: 100, label: "a"),
                       to: JumpHistory.Entry(url: nil, offset: 300, label: "c"))
        #expect(!history.canGoForward)
    }

    // MARK: - Export (§9.5)

    @Test @MainActor func htmlExportIsSelfContainedAndEscaped() {
        let markdown = """
        # Title & <Tag>

        A paragraph with **bold**, `code`, and a [link](https://example.com).

        - [x] done
        - [ ] not done

        | a | b |
        |---|--:|
        | 1 | 2 |

        ```swift
        let x = "<script>"
        ```
        """
        let document = MarkdownParser.parse(markdown)
        let html = HTMLExporter(
            document: document, theme: ThemeStore.shared.current,
            title: "Test", baseDirectory: nil, imageProvider: nil
        ).html()

        #expect(html.contains("<style>"), "styles must be inlined")
        #expect(!html.contains("<link rel=\"stylesheet\""), "must not reference an external stylesheet")
        #expect(!html.contains("<script src="), "must not reference external scripts")
        #expect(html.contains("Title &amp; &lt;Tag&gt;"), "heading text must be escaped")
        #expect(html.contains("&lt;script&gt;"), "code contents must be escaped")
        #expect(html.contains("<strong>"))
        #expect(html.contains("type=\"checkbox\""))
        #expect(html.contains("<table>"))
        #expect(html.contains("text-align:right"), "table alignment must survive")
    }

    @Test @MainActor func htmlExportRewritesRelativeMarkdownLinks() {
        let document = MarkdownParser.parse("See [the plan](plan.md) and [the web](https://example.com).")
        let html = HTMLExporter(
            document: document, theme: ThemeStore.shared.current,
            title: "T", baseDirectory: nil, imageProvider: nil
        ).html()
        #expect(html.contains("href=\"plan.html\""), "sibling exports stay navigable")
        #expect(html.contains("href=\"https://example.com\""), "absolute links are untouched")
    }

    /// Regression: wikilink targets used to ship as live `href`s with no
    /// scheme check.  `[[javascript:alert(1)//]]` exported as
    /// `href="javascript:alert(1)//.html"` — the `//` comments the suffix out
    /// of the script, so opening the export and clicking ran the payload.
    @Test @MainActor func htmlExportMakesUnsafeWikilinkTargetsInert() {
        let document = MarkdownParser.parse(
            """
            [[javascript:alert(document.domain)//]] [[data:text/html;base64,x]]
            [[Notes]] [[deep/note|with a label]]
            """
        )
        let html = HTMLExporter(
            document: document, theme: ThemeStore.shared.current,
            title: "T", baseDirectory: nil, imageProvider: nil
        ).html()
        #expect(!html.lowercased().contains("href=\"javascript:"), "script wikilinks must not be live")
        #expect(!html.lowercased().contains("href=\"data:"), "data wikilinks must not be live")
        #expect(!html.contains("href=\"javascript:alert(document.domain)//.html\""))
        #expect(html.contains("href=\"Notes.html\""), "plain wikilinks still export")
        #expect(html.contains("href=\"deep/note.html\""), "labelled wikilinks still export")
        #expect(html.contains(">with a label<"))
    }

    @Test @MainActor func htmlExportKeepsDeepHeadingHierarchy() {
        let markdown = "# H1\n\n## H2\n\n### H3\n\n#### H4\n\n##### H5\n\n###### H6\n"
        let html = HTMLExporter(
            document: MarkdownParser.parse(markdown),
            theme: ThemeStore.shared.current,
            title: "T", baseDirectory: nil, imageProvider: nil
        ).html()

        #expect(html.contains("h1 { color:") && html.contains("font-weight: 700; letter-spacing: -0.022em"))
        #expect(html.contains("h2 { color:") && html.contains("font-weight: 700; letter-spacing: -0.014em"))
        #expect(html.contains("h3 { color:") && html.contains("font-weight: 700; letter-spacing: -0.014em"))
        #expect(html.contains("font-weight: 600; letter-spacing: normal"))
        #expect(html.contains("font-weight: 600; letter-spacing: 0.04em"))
        #expect(html.contains("font-weight: 500; font-style: italic; letter-spacing: 0.06em"))
    }

    // MARK: - HTML export confinement (§9.5)

    private func makeExportRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func pngData() -> Data {
        // A 1×1 transparent PNG — small enough that embedding succeeds.
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
    }

    private func exportHTML(_ markdown: String, baseDirectory: URL) -> String {
        HTMLExporter(
            document: MarkdownParser.parse(markdown),
            theme: ThemeStore.shared.current,
            title: "T", baseDirectory: baseDirectory, imageProvider: nil
        ).html()
    }

    @Test @MainActor func htmlExportEmbedsOnlyImagesInsideTheBaseDirectory() throws {
        let root = try makeExportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try pngData().write(to: root.appendingPathComponent("inside.png"))
        // A sibling file outside the export root — the leak that motivated the
        // containment rule.
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-outside-\(UUID().uuidString).png")
        try pngData().write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let html = exportHTML(
            "![in](inside.png) ![leak](../\(outside.lastPathComponent)) ![abs](/etc/hosts)",
            baseDirectory: root
        )

        // The contained image is inlined; both escapes are refused.
        #expect(html.contains("data:image/png;base64,"))
        #expect(html.contains("data:image/png;base64,iVBORw0KGgo"))
        #expect(html.filter { $0 == "," }.count >= 1)  // sanity: some data URI present
        // Only one data URI: the inlined image.  The escapes must not embed.
        let dataURIcount = html.components(separatedBy: "data:image/").count - 1
        #expect(dataURIcount == 1, "escapes must not be base64-embedded")
        #expect(html.contains("class=\"missing\""))
        // The escaped source path may appear as the broken-image label, but the
        // file's contents (its PNG base64) must never be inlined twice more.
        #expect(html.components(separatedBy: "class=\"missing\"").count - 1 == 2)
    }

    @Test @MainActor func htmlExportRefusesTraversalAndAbsolutePaths() throws {
        let root = try makeExportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-secret-\(UUID().uuidString).png")
        try pngData().write(to: secret)
        defer { try? FileManager.default.removeItem(at: secret) }

        // `../` points at the temporary directory the secret lives in.
        let parent = root.deletingLastPathComponent()
        let traversal = "../\(parent.lastPathComponent)/\(secret.lastPathComponent)"
        let html = exportHTML(
            "![t](\(traversal)) ![a](/private/var/etc/passwd)",
            baseDirectory: root
        )

        #expect(!html.contains("data:image/"), "no local file may be embedded")
        #expect(html.components(separatedBy: "class=\"missing\"").count - 1 == 2)
    }

    @Test @MainActor func htmlExportDoesNotEmbedOversizedImages() throws {
        let root = try makeExportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let huge = root.appendingPathComponent("huge.png")
        try Data(repeating: 0xFF, count: 5 * 1024 * 1024 + 1).write(to: huge)

        let html = exportHTML("![big](huge.png)", baseDirectory: root)
        #expect(!html.contains("data:image/"))
        #expect(html.contains("class=\"missing\""))
    }

    @Test @MainActor func htmlExportNeverRetainsActiveExternalImageSources() throws {
        let root = try makeExportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let html = exportHTML(
            "![web](https://tracker.example/pixel.png) "
                + "![file](file:///private/etc/passwd) "
                + "![data](data:image/svg+xml,<svg/>) "
                + "![protocol](//tracker.example/pixel.png)",
            baseDirectory: root
        )

        #expect(!html.contains("<img src=\"https://"))
        #expect(!html.contains("<img src=\"file:"))
        #expect(!html.contains("<img src=\"data:"))
        #expect(!html.contains("<img src=\"//"))
        #expect(html.components(separatedBy: "class=\"missing\"").count - 1 == 4)
    }

    @Test func plainTextRenderingStripsMarkup() {
        let markdown = "# Heading\n\nSome **bold** and `code` and a [link](https://x.test).\n"
        let document = MarkdownParser.parse(markdown)
        let plain = PlainTextRenderer.render(
            document, range: NSRange(location: 0, length: document.length)
        )
        #expect(!plain.contains("**"))
        #expect(!plain.contains("`"))
        #expect(!plain.contains("]("))
        #expect(plain.contains("link"), "link text survives, the target does not")
    }

    @Test func slugsMatchGitHubConventions() {
        #expect(Slugs.make("Hello, World!") == "hello-world")
        #expect(Slugs.make("  spaced  out  ") == "spaced-out")
        #expect(Slugs.make("§8.1 Rendered diff") == "81-rendered-diff")
    }

    // MARK: - Sibling scanning (§8.7)

    @Test func siblingScannerFindsMarkdownInDocsSubdirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-siblings-\(UUID().uuidString)", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let main = root.appendingPathComponent("PLAN.md")
        try Data("# Plan\n".utf8).write(to: main)
        try Data("# Notes\n".utf8).write(to: root.appendingPathComponent("NOTES.md"))
        try Data("# Deep\n".utf8).write(to: docs.appendingPathComponent("DEEP.md"))
        try Data("not markdown".utf8).write(to: root.appendingPathComponent("data.csv"))

        let scanner = SiblingScanner(documentURL: main, extraDirectories: ["docs"])
        let names = Set(scanner.siblings.map(\.displayName))
        #expect(names == ["PLAN", "NOTES", "DEEP"])
        #expect(scanner.siblings.contains { $0.group == "docs" })
        #expect(scanner.siblings.first?.isCurrent == true, "the open document sorts first")
    }
}
