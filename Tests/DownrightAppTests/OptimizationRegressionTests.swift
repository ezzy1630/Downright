import Foundation
import Testing
import MarkdownCore
@testable import DownrightApp

@Suite(.serialized)
struct OptimizationRegressionTests {
    @Test
    func contentHashAPIsAgree() {
        let text = "# Hello\n\nWorld\n"
        #expect(DocumentIO.contentHash(text) == SnapshotStore.hash(text))
        #expect(DocumentIO.contentHash(Data(text.utf8)) == SnapshotStore.hash(Data(text.utf8)))
    }

    @Test
    func documentWordCountIgnoresCode() {
        let doc = MarkdownParser.parse("""
        # Title

        Two words here.

        ```swift
        let ignored = true
        ```
        """)
        let count = Metrics.documentWordCount(doc)
        #expect(count == 4) // Title + Two words here
    }

    @Test
    func fuzzyMatcherFindsSubsequence() {
        let match = FuzzyMatcher.match(needle: "dpl", in: "Document pipeline")
        #expect(match != nil)
        #expect(FuzzyMatcher.match(needle: "zzz", in: "Document pipeline") == nil)
    }

    @Test
    func findSessionClears() {
        let session = FindSession()
        var query = FindQuery()
        query.text = "alpha"
        session.update(query: query, in: "alpha beta alpha", caret: 0)
        #expect(session.matches.count == 2)
        session.clear()
        #expect(session.matches.isEmpty)
        #expect(session.query.isEmpty)
    }

    @Test
    func workspaceSearchLoadsTextOnDemand() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-ws-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("note.md")
        let body = "# Intro\n\nShip the release.\n"
        try Data(body.utf8).write(to: file)

        let entry = WorkspaceIndexEntry(
            url: file, relativePath: "note.md", text: "",
            headings: [WorkspaceHeading(title: "Intro", range: NSRange(location: 0, length: 7), level: 1)],
            frontMatter: [], links: [], byteCount: Int64(body.utf8.count)
        )
        let snapshot = WorkspaceIndexSnapshot(rootURL: root, revision: 1, entries: [entry])
        let results = WorkspaceSearch.search(WorkspaceSearchQuery(text: "release"), in: snapshot)
        let result = try #require(results.first)
        #expect(result.contextText == "Ship the release.")
        #expect(result.line == 3)
    }

    @Test
    func workspaceSearchRejectsFilesThatOutgrowTheirIndexedBound() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-ws-search-bound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("note.md")
        let indexed = "# Note\n"
        try Data((indexed + String(repeating: "oversized ", count: 10_000)).utf8).write(to: file)
        let entry = WorkspaceIndexEntry(
            url: file, relativePath: "note.md", text: "", headings: [],
            frontMatter: [], links: [], byteCount: Int64(indexed.utf8.count)
        )
        let snapshot = WorkspaceIndexSnapshot(rootURL: root, revision: 1, entries: [entry])

        #expect(WorkspaceSearch.search(
            WorkspaceSearchQuery(text: "oversized"), in: snapshot
        ).isEmpty)
    }

    @Test
    func scrollAnchoringHandlesPreambleOffsets() {
        let text = "Introductory preamble paragraph before any heading.\n\n# Heading 1\nSection 1 text\n"
        let doc = MarkdownParser.parse(text)
        let anchor = ScrollAnchoring.anchor(for: 10, in: doc)
        #expect(anchor.headingSlug == "")
        #expect(anchor.headingIndex == 0)
        let restoredOffset = ScrollAnchoring.offset(for: anchor, in: doc)
        #expect(restoredOffset >= 8 && restoredOffset <= 12)
    }

    @Test
    func snapshotStoreObjectInventoryPreservesShardDirectories() {
        let inventory = SnapshotStore.shared.objectInventory()
        for item in inventory {
            #expect(item.hash.count == 64)
            #expect(item.url.lastPathComponent.count == 64)
        }
    }

    @Test
    func markdownParseCoordinatorAcceptsZeroRevisionOnSubmit() async {
        let coordinator = MarkdownParseCoordinator(worker: MarkdownParseWorker())
        let request = MarkdownParseRequest(
            text: "# Title\nContent",
            previous: .empty,
            revision: .zero
        )
        await coordinator.submit(request)
        let result = await coordinator.nextResult()
        #expect(result?.document.headings.count == 1)
        #expect(result?.document.headings.first?.title == "Title")
        #expect(result?.revision == .zero)
    }
}
