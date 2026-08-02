import Foundation
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
        let store = SnapshotStore.shared
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-test-\(UUID().uuidString).md")
        defer { store.forget(url) }

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
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(DocumentState.self, from: data)
        #expect(decoded.selectionLocation == 42)
        #expect(decoded.selectionLength == 7)
        #expect(decoded.splitViewEnabled)
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

    // MARK: - Key bindings (§7.2)

    @Test func keyBindingRoundTripsThroughItsStringForm() throws {
        for source in ["cmd+e", "cmd+shift+o", "opt+down", "space", "shift+space", "ctrl+opt+shift+cmd+k", "["] {
            let binding = try #require(KeyBinding(parsing: source), "failed to parse \(source)")
            #expect(KeyBinding(parsing: binding.serialized) == binding)
        }
    }

    @Test func defaultBindingsMatchTheSpecTable() {
        let store = KeybindingStore.shared
        #expect(store.primaryBinding(for: .toggleReadLive) == KeyBinding("e", .command))
        #expect(store.primaryBinding(for: .sourceMode) == KeyBinding("e", [.command, .shift]))
        #expect(store.primaryBinding(for: .toggleSidebar) == KeyBinding("0", .command))
        #expect(store.primaryBinding(for: .outlineQuickOpen) == KeyBinding("o", [.command, .shift]))
        #expect(store.primaryBinding(for: .versionTimeline) == KeyBinding("v", [.command, .shift]))
        #expect(store.primaryBinding(for: .nextChange) == KeyBinding("down", .option))
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
