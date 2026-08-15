import AppKit
import Foundation
import MarkdownCore
import Testing
@testable import DownrightApp

@MainActor
@Suite(.serialized)
struct WorkspaceTests {
    @Test
    func policyAcceptsMarkdownAndSkipsHiddenBuildVendor() {
        let policy = WorkspaceIndexPolicy()
        #expect(policy.accepts(URL(fileURLWithPath: "/tmp/readme.md"), isDirectory: false))
        #expect(!policy.accepts(URL(fileURLWithPath: "/tmp/readme.txt"), isDirectory: false))
        #expect(!policy.accepts(URL(fileURLWithPath: "/tmp/.git"), isDirectory: true))
        #expect(!policy.accepts(URL(fileURLWithPath: "/tmp/vendor"), isDirectory: true))
        #expect(policy.accepts(URL(fileURLWithPath: "/tmp/docs"), isDirectory: true))
    }

    @Test
    func injectedIndexExtractsHeadingsFrontMatterAndLinks() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let file = root.appendingPathComponent("docs/guide.md")
        let source = "---\ntitle: Guide\n---\n\n# Guide\n\nSee [Home](../README.md) and [[Notes]].\n"
        let index = WorkspaceIndex(
            policy: WorkspaceIndexPolicy(readConcurrency: 2),
            enumerator: { _, _ in [file] },
            reader: { _ in (source, Int64(source.utf8.count)) }
        )
        let signal = WorkspaceSignal()
        index.onUpdate = { _ in signal.signal() }
        index.start(rootURL: root)
        await signal.wait()

        let entry = try #require(index.snapshot.entries.first)
        #expect(entry.relativePath == "docs/guide.md")
        #expect(entry.headings.first?.title == "Guide")
        #expect(entry.frontMatter.first?.key == "title")
        #expect(entry.links.count == 2)
        #expect(entry.links.first?.range == source.nsRange(of: "[Home](../README.md)"))
    }

    @Test
    func latestRevisionWinsWhenASecondScanStarts() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let first = root.appendingPathComponent("first.md")
        let gate = WorkspaceReadGate()
        let index = WorkspaceIndex(
            policy: WorkspaceIndexPolicy(),
            enumerator: { _, _ in [first] },
            reader: { url in
                if url == first { gate.wait() }
                return ("# \(url.lastPathComponent)", 10)
            }
        )
        var updates: [Int] = []
        index.onUpdate = { updates.append($0.revision) }
        index.start(rootURL: root)
        #expect(await gate.waitUntilBlocked())
        // A new scan has a new revision.  The old scan may finish later but
        // cannot publish its snapshot.
        index.start(rootURL: root.appendingPathComponent("second"))
        gate.release()
        for _ in 0..<100 where updates.isEmpty { await Task.yield() }
        #expect(updates == [2])
        #expect(index.snapshot.revision == 2)
    }

    @Test
    func indexEnforcesTotalByteBudget() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        let index = WorkspaceIndex(
            policy: WorkspaceIndexPolicy(maximumTotalBytes: 10, readConcurrency: 2),
            enumerator: { _, _ in [first, second] },
            reader: { url in (url.lastPathComponent, 6) }
        )
        let signal = WorkspaceSignal()
        index.onUpdate = { _ in signal.signal() }
        index.start(rootURL: root)
        await signal.wait()

        #expect(index.snapshot.entries.count == 1)
        #expect(index.snapshot.entries.reduce(0) { $0 + $1.byteCount } <= 10)
        #expect(index.snapshot.skippedFiles == 1)
    }

    @Test
    func siblingUnseenStateUsesContentHash() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-sibling-hash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let current = root.appendingPathComponent("CURRENT.md")
        let sibling = root.appendingPathComponent("SIBLING.md")
        let original = "# Same\n"
        try Data(original.utf8).write(to: current)
        try Data(original.utf8).write(to: sibling)

        var state = DocumentStateStore.shared.state(for: sibling)
        state.lastSeenHash = SnapshotStore.hash(original)
        DocumentStateStore.shared.save(state, for: sibling)

        let scanner = SiblingScanner(documentURL: current, extraDirectories: [])
        #expect(scanner.siblings.count == 2)
        #expect(scanner.siblings.first(where: { $0.url.lastPathComponent == sibling.lastPathComponent })?.hasUnseenChanges == false)

        try Data("# Changed\n".utf8).write(to: sibling)
        scanner.scan(synchronously: true)
        #expect(scanner.siblings.first(where: { $0.url.lastPathComponent == sibling.lastPathComponent })?.hasUnseenChanges == true)
    }

    @Test
    func searchReturnsExactFileRangeAndContext() throws {
        let entry = WorkspaceIndexEntry(
            url: URL(fileURLWithPath: "/workspace/readme.md"), relativePath: "readme.md",
            text: "# Intro\n\nShip the release.\n", headings: [WorkspaceHeading(title: "Intro", range: NSRange(location: 0, length: 7), level: 1)],
            frontMatter: [], links: [], byteCount: 28
        )
        let snapshot = WorkspaceIndexSnapshot(rootURL: URL(fileURLWithPath: "/workspace"), revision: 1, entries: [entry])
        let results = WorkspaceSearch.search(WorkspaceSearchQuery(text: "release"), in: snapshot)
        let result = try #require(results.first)
        #expect(result.range == entry.text.nsRange(of: "release"))
        #expect(result.contextText == "Ship the release.")
        #expect(result.line == 3)
        #expect(result.heading == "Intro")
    }

    @Test
    func graphResolvesRelativeLinksAndBacklinks() throws {
        let root = URL(fileURLWithPath: "/workspace")
        let readme = WorkspaceIndexEntry(
            url: root.appendingPathComponent("README.md"), relativePath: "README.md", text: "", headings: [], frontMatter: [],
            links: [WorkspaceLink(destination: "docs/guide.md", range: NSRange(location: 0, length: 18), kind: .markdown)], byteCount: 0
        )
        let guide = WorkspaceIndexEntry(
            url: root.appendingPathComponent("docs/guide.md"), relativePath: "docs/guide.md", text: "", headings: [], frontMatter: [],
            links: [], byteCount: 0
        )
        let snapshot = WorkspaceIndexSnapshot(rootURL: root, revision: 1, entries: [readme, guide])
        let graph = WorkspaceLinkGraphBuilder.build(snapshot: snapshot)
        #expect(graph.unresolved.isEmpty)
        #expect(graph.linksTo(fileID: guide.id).count == 1)
        #expect(graph.linksTo(fileID: guide.id).first?.sourceFile == readme.id)
    }

    @Test
    func graphToleratesNormalizedPathCollisions() {
        // `normalize` folds backslashes to slashes and trims a leading `./`, so
        // `a\b.md` collides with `a/b.md` and `.x.md` with `x.md`.  The builder
        // used to trap on the first duplicate; it must instead prefer the
        // already-normalized path deterministically.
        let root = URL(fileURLWithPath: "/workspace")
        let slash = WorkspaceIndexEntry(
            url: URL(fileURLWithPath: "/workspace/a/b.md"), relativePath: "a/b.md",
            text: "", headings: [], frontMatter: [], links: [], byteCount: 0
        )
        let backslash = WorkspaceIndexEntry(
            url: URL(fileURLWithPath: "/workspace/a\\b.md"), relativePath: "a\\b.md",
            text: "", headings: [], frontMatter: [], links: [], byteCount: 0
        )
        let visible = WorkspaceIndexEntry(
            url: URL(fileURLWithPath: "/workspace/x.md"), relativePath: "x.md",
            text: "", headings: [], frontMatter: [], links: [], byteCount: 0
        )
        let hidden = WorkspaceIndexEntry(
            url: URL(fileURLWithPath: "/workspace/.x.md"), relativePath: ".x.md",
            text: "", headings: [], frontMatter: [], links: [], byteCount: 0
        )
        let source = WorkspaceIndexEntry(
            url: URL(fileURLWithPath: "/workspace/notes.md"), relativePath: "notes.md",
            text: "", headings: [], frontMatter: [],
            links: [
                WorkspaceLink(destination: "a/b.md", range: NSRange(location: 0, length: 6), kind: .markdown),
                WorkspaceLink(destination: "x.md", range: NSRange(location: 7, length: 4), kind: .markdown),
            ],
            byteCount: 0
        )
        let snapshot = WorkspaceIndexSnapshot(
            rootURL: root, revision: 1, entries: [slash, backslash, visible, hidden, source]
        )
        let graph = WorkspaceLinkGraphBuilder.build(snapshot: snapshot)
        let resolved = Set(graph.outgoing[source.id]?.compactMap(\.targetFile) ?? [])
        #expect(resolved.contains(slash.id))
        #expect(resolved.contains(visible.id))
        #expect(!resolved.contains(backslash.id))
        #expect(!resolved.contains(hidden.id))
        #expect(graph.unresolved.isEmpty)
    }

    @Test
    func sidebarShowsTreeSearchAndAccessibleRows() throws {
        let entry = WorkspaceIndexEntry(
            url: URL(fileURLWithPath: "/workspace/readme.md"), relativePath: "readme.md", text: "# Readme", headings: [], frontMatter: [], links: [], byteCount: 8
        )
        let view = WorkspaceSidebarView()
        let delegate = RecordingWorkspaceDelegate()
        view.delegate = delegate
        view.entries = [entry]
        #expect(view.numberOfRows(in: NSTableView()) == 1)
        let row = try #require(view.tableView(NSTableView(), viewFor: nil, row: 0))
        #expect(row.accessibilityLabel()?.contains("readme.md") == true)
        view.selectedTab = .search
        view.setSearchTextForTesting("readme")
        #expect(delegate.queries.first?.text == "readme")
        #expect(view.accessibilityLabel() == "Workspace")
    }

}

private extension String {
    func nsRange(of value: String) -> NSRange {
        (self as NSString).range(of: value)
    }
}

@MainActor
private final class WorkspaceSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var didSignal = false

    func signal() {
        didSignal = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if didSignal { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

private final class WorkspaceReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = false
    private var released = false

    func wait() {
        condition.lock()
        blocked = true
        condition.broadcast()
        let deadline = Date().addingTimeInterval(5)
        while !released && condition.wait(until: deadline) {
            // The condition may wake spuriously; re-check the release flag.
        }
        condition.unlock()
    }

    func waitUntilBlocked() async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            condition.lock()
            let ready = blocked
            condition.unlock()
            if ready { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

@MainActor
private final class RecordingWorkspaceDelegate: WorkspaceSidebarViewDelegate {
    var queries: [WorkspaceSearchQuery] = []

    func workspaceSidebar(_ view: WorkspaceSidebarView, didSelect url: URL, range: NSRange?, inNewWindow: Bool) {}
    func workspaceSidebar(_ view: WorkspaceSidebarView, didSearch query: WorkspaceSearchQuery) { queries.append(query) }
}
