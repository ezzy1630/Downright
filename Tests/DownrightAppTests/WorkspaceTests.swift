import AppKit
import Darwin
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
        await gate.waitUntilBlocked()
        // A new scan has a new revision.  The old scan may finish later but
        // cannot publish its snapshot.
        index.start(rootURL: root.appendingPathComponent("second"))
        gate.release()
        for _ in 0..<100 where updates.isEmpty { await Task.yield() }
        #expect(updates == [2])
        #expect(index.snapshot.revision == 2)
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

    @Test
    func navigatorIsTransientWidthAndSearchesBothSections() throws {
        let navigator = NavigationPanelView()
        #expect(navigator.preferredWidth >= 300 && navigator.preferredWidth <= 320)
        #expect(navigator.accessibilityLabel() == "Contents and Files")

        navigator.headings = MarkdownParser.parse("# Intro\n\n## Details\n").headings
        navigator.filterText = "details"
        #expect(navigator.headings.count == 2, "source headings stay intact while the Contents view filters")
        #expect(navigator.visibleHeadingCountForTesting == 1)

        let file = SiblingScanner.Sibling(
            url: URL(fileURLWithPath: "/workspace/notes.md"),
            displayName: "notes.md", modified: Date(), byteCount: 0, hasUnseenChanges: false, group: nil, isCurrent: false
        )
        navigator.siblings = [file]
        navigator.filterText = "missing"
        #expect(navigator.siblings.count == 1, "source files stay intact while the Files view filters")
        #expect(navigator.visibleFileCountForTesting == 0)
        #expect(navigator.visibleSectionCountForTesting == 0)
        #expect(navigator.emptyStateVisibleForTesting)

        navigator.filterText = ""
        #expect(navigator.visibleSectionCountForTesting == 2)
        #expect(!navigator.emptyStateVisibleForTesting)
        #expect(navigator.preferredHeight < NavigationPanelGeometry.maximumHeight)
    }

    @Test
    func navigatorGeometryStaysInsetAndOnScreen() {
        let content = NSRect(x: 980, y: 120, width: 500, height: 700)
        let visible = NSRect(x: 1000, y: 100, width: 420, height: 760)
        let frame = NavigationPanelGeometry.frame(
            contentScreenFrame: content,
            visibleScreenFrame: visible
        )
        #expect(frame.width == 312)
        #expect(frame.height <= 560)
        #expect(frame.minX >= visible.minX + 12)
        #expect(frame.maxX <= visible.maxX - 12)
        #expect(frame.minY >= visible.minY + 12)
        #expect(frame.maxY <= visible.maxY - 12)

        let compactFrame = NavigationPanelGeometry.frame(
            contentScreenFrame: content,
            visibleScreenFrame: visible,
            preferredHeight: 240
        )
        #expect(compactFrame.height == 240)
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
    private let lock = NSLock()
    private var blocked = false
    private var released = false

    func wait() {
        lock.withLock { blocked = true }
        while true {
            let done = lock.withLock { released }
            if done { return }
            Darwin.usleep(1_000)
        }
    }

    func waitUntilBlocked() async {
        while true {
            let ready = lock.withLock { blocked }
            if ready { return }
            await Task.yield()
        }
    }

    func release() {
        lock.withLock { released = true }
    }
}

@MainActor
private final class RecordingWorkspaceDelegate: WorkspaceSidebarViewDelegate {
    var queries: [WorkspaceSearchQuery] = []

    func workspaceSidebar(_ view: WorkspaceSidebarView, didSelect url: URL, range: NSRange?, inNewWindow: Bool) {}
    func workspaceSidebar(_ view: WorkspaceSidebarView, didSearch query: WorkspaceSearchQuery) { queries.append(query) }
}
