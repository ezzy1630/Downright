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
}
