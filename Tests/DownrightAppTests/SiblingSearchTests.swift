import AppKit
import Foundation
import MarkdownRender
import Testing
@testable import DownrightApp

@MainActor
@Suite(.serialized)
struct SiblingSearchTests {
    @Test
    func typingRefreshesSiblingResults() async throws {
        let fixture = try Fixture(files: [
            "CURRENT.md": "# Current\n\nNothing here.\n",
            "NOTES.md": "# Notes\n\nThe reactive needle is here.\n",
        ])
        defer { fixture.remove() }

        let controller = try fixture.openController()
        defer { controller.close() }

        controller.showSiblingSearch()
        let bar = try #require(controller.findBar)
        let results = try #require(controller.searchResults)
        #expect(controller.siblingSearchActive)
        #expect(results.query.isEmpty)
        #expect(!results.isSearching)

        bar.setQueryText("needle")

        #expect(await eventually {
            results.query == "needle"
                && !results.isSearching
                && results.hits.count == 1
        })
        #expect(results.hits.first?.url.lastPathComponent == "NOTES.md")
        #expect(controller.currentFindQuery.text == "needle")
    }

    @Test
    func aSlowOldQueryCannotReplaceNewerResults() async throws {
        let fixture = try Fixture(files: [
            "CURRENT.md": "# Current\n",
            "OLD.md": "The old query lands here.\n",
            "NEW.md": "The new query lands here.\n",
        ])
        defer { fixture.remove() }

        let controller = try fixture.openController()
        defer { controller.close() }
        let gate = BlockingSearch(query: "old")
        defer { gate.release() }
        controller.siblingSearchRunner = { query, urls, shouldCancel in
            gate.run(query, urls, shouldCancel)
        }

        controller.showSiblingSearch()
        let bar = try #require(controller.findBar)
        let results = try #require(controller.searchResults)
        bar.setQueryText("old")
        #expect(await gate.waitUntilStarted())

        bar.setQueryText("new")
        // The keystroke retires the visible old result immediately, before
        // the debounced filesystem pass has a chance to begin.
        #expect(results.query == "new")
        #expect(results.hits.isEmpty)
        #expect(results.isSearching)
        #expect(await eventually { controller.currentFindQuery.text == "new" })

        gate.release()
        await drainSiblingSearchQueue(controller)
        #expect(results.query == "new")
        #expect(!results.isSearching)
        #expect(results.hits.map(\.url.lastPathComponent) == ["NEW.md"])
    }

    @Test
    func closingTheInspectorInvalidatesAnInFlightSearch() async throws {
        let fixture = try Fixture(files: [
            "CURRENT.md": "# Current\n",
            "BLOCKED.md": "The blocked query lands here.\n",
        ])
        defer { fixture.remove() }

        let controller = try fixture.openController()
        defer { controller.close() }
        let gate = BlockingSearch(query: "blocked")
        defer { gate.release() }
        controller.siblingSearchRunner = { query, urls, shouldCancel in
            gate.run(query, urls, shouldCancel)
        }

        controller.showSiblingSearch()
        let bar = try #require(controller.findBar)
        let results = try #require(controller.searchResults)
        bar.setQueryText("blocked")
        #expect(await gate.waitUntilStarted())

        controller.closeInspector(restoringFocus: false)
        #expect(!controller.siblingSearchActive)
        #expect(!results.isSearching)

        gate.release()
        await drainSiblingSearchQueue(controller)
        #expect(results.hits.isEmpty)
    }

    @Test
    func replacingTheScannerInvalidatesOldDirectoryResults() async throws {
        let oldFixture = try Fixture(files: [
            "CURRENT.md": "# Current\n",
            "OLD.md": "The shared query belongs to the old directory.\n",
        ])
        let newFixture = try Fixture(files: [
            "CURRENT.md": "# Replacement\n",
            "NEW.md": "The shared query belongs to the new directory.\n",
        ])
        defer {
            oldFixture.remove()
            newFixture.remove()
        }

        let controller = try oldFixture.openController()
        defer { controller.close() }
        let gate = BlockingSearch(query: "shared")
        defer { gate.release() }
        controller.siblingSearchRunner = { query, urls, shouldCancel in
            gate.run(query, urls, shouldCancel)
        }

        controller.showSiblingSearch()
        let bar = try #require(controller.findBar)
        let results = try #require(controller.searchResults)
        bar.setQueryText("shared")
        #expect(await gate.waitUntilStarted())

        controller.scanner = SiblingScanner(
            documentURL: newFixture.current,
            extraDirectories: []
        )
        #expect(results.query == "shared")
        #expect(results.hits.isEmpty)
        #expect(results.isSearching)

        gate.release()
        await drainSiblingSearchQueue(controller)
        #expect(await eventually {
            !results.isSearching
                && results.hits.map(\.url.lastPathComponent) == ["NEW.md"]
        })
    }

    @Test
    func inPlaceNavigationRefreshesTheVisibleSearchInTheNewDirectory() async throws {
        let oldFixture = try Fixture(files: [
            "CURRENT.md": "# Current\n",
            "OLD.md": "The shared query belongs to the old directory.\n",
        ])
        let newFixture = try Fixture(files: [
            "CURRENT.md": "# Replacement\n",
            "NEW.md": "The shared query belongs to the new directory.\n",
        ])
        defer {
            oldFixture.remove()
            newFixture.remove()
        }

        let controller = try oldFixture.openController()
        defer { controller.close() }
        controller.showSiblingSearch()
        let bar = try #require(controller.findBar)
        let results = try #require(controller.searchResults)
        bar.setQueryText("shared")
        #expect(await eventually {
            !results.isSearching
                && results.hits.map(\.url.lastPathComponent) == ["OLD.md"]
        })

        controller.openInPlace(newFixture.current)

        #expect(controller.inspectorHost?.selectedSection == .search)
        #expect(controller.siblingSearchActive)
        #expect(await eventually {
            !results.isSearching
                && results.hits.map(\.url.lastPathComponent) == ["NEW.md"]
        })
    }

    @Test
    func aSameScannerRescanRefreshesTheVisibleQuery() async throws {
        let fixture = try Fixture(files: [
            "CURRENT.md": "# Current\n",
            "NOTES.md": "The live needle starts here.\n",
        ])
        defer { fixture.remove() }

        let controller = try fixture.openController()
        defer { controller.close() }
        controller.showSiblingSearch()
        let bar = try #require(controller.findBar)
        let results = try #require(controller.searchResults)
        bar.setQueryText("needle")
        #expect(await eventually {
            !results.isSearching
                && results.hits.map(\.url.lastPathComponent) == ["NOTES.md"]
        })

        try fixture.write("The live needle moved here.\n", to: "ADDED.md")
        try fixture.write("No match remains in notes.\n", to: "NOTES.md")
        controller.scanner?.scan(synchronously: true, computeChanges: false)
        #expect(await eventually {
            !results.isSearching
                && results.searchedFileCount == 3
                && results.hits.map(\.url.lastPathComponent) == ["ADDED.md"]
        })

        try fixture.delete("ADDED.md")
        controller.scanner?.scan(synchronously: true, computeChanges: false)
        #expect(await eventually {
            !results.isSearching
                && results.searchedFileCount == 2
                && results.hits.isEmpty
        })
    }

    @Test
    func selectingAnotherInspectorStopsHiddenSiblingScans() async throws {
        let fixture = try Fixture(files: [
            "CURRENT.md": "# Current\n\n- [ ] One task\n",
            "NOTES.md": "The hidden needle is nearby.\n",
        ])
        defer { fixture.remove() }

        let controller = try fixture.openController()
        defer { controller.close() }
        let counter = CountingSearch()
        controller.siblingSearchRunner = { query, urls, shouldCancel in
            counter.run(query, urls, shouldCancel)
        }
        controller.showSiblingSearch()
        let bar = try #require(controller.findBar)
        let results = try #require(controller.searchResults)
        bar.setQueryText("needle")
        #expect(await eventually { !results.isSearching && counter.count > 0 })
        await drainSiblingSearchQueue(controller)
        let completedSearches = counter.count

        controller.toggleTaskPanel()
        #expect(controller.inspectorHost?.selectedSection == .tasks)
        #expect(!controller.siblingSearchActive)

        // Document edits eventually call this same Find refresh path. A hidden
        // sibling panel must not turn that local refresh into filesystem work.
        controller.runFind(controller.currentFindQuery, scrollToMatch: false)
        await drainSiblingSearchQueue(controller)
        #expect(counter.count == completedSearches)
    }

    @Test
    func removingContextReactivatesTheRetainedSearch() async throws {
        let fixture = try Fixture(files: [
            "CURRENT.md": "# Current\n",
            "NOTES.md": "The returning needle starts here.\n",
        ])
        defer { fixture.remove() }

        let controller = try fixture.openController()
        defer { controller.close() }
        controller.showSiblingSearch()
        let bar = try #require(controller.findBar)
        let results = try #require(controller.searchResults)
        bar.setQueryText("needle")
        #expect(await eventually {
            !results.isSearching
                && results.hits.map(\.url.lastPathComponent) == ["NOTES.md"]
        })

        let context = NSView()
        controller.installTrailing(context, title: "Document")
        #expect(controller.inspectorHost?.selectedSection == .context)
        #expect(!controller.siblingSearchActive)

        try fixture.write("No match remains in notes.\n", to: "NOTES.md")
        try fixture.write("The returning needle moved here.\n", to: "ADDED.md")
        controller.scanner?.scan(synchronously: true, computeChanges: false)

        controller.dismissTrailing(context)
        #expect(controller.inspectorHost?.selectedSection == .search)
        #expect(controller.siblingSearchActive)
        #expect(await eventually {
            !results.isSearching
                && results.hits.map(\.url.lastPathComponent) == ["ADDED.md"]
        })
    }

    @Test
    func anImmediateReopenOwnsAFreshFloatingSurface() throws {
        let fixture = try Fixture(files: [
            "CURRENT.md": "# Current\n",
            "NOTES.md": "# Notes\n",
        ])
        defer { fixture.remove() }

        let controller = try fixture.openController()
        defer { controller.close() }
        controller.activeStyleSheet = StyleSheet(
            theme: ThemeStore.shared.current,
            appearance: NSApp.effectiveAppearance,
            reduceMotionOverride: false
        )
        controller.window?.makeKeyAndOrderFront(nil)

        controller.showSiblingSearch()
        let first = try #require(controller.floatingSurface)
        controller.closeInspector(restoringFocus: false)
        #expect(first.isDismissing)

        controller.showSiblingSearch()
        let reopened = try #require(controller.floatingSurface)
        #expect(reopened !== first)
        #expect(!reopened.isDismissing)
        #expect(controller.siblingSearchActive)

        // Settling the retired surface must not tear down the replacement.
        first.settleForTesting()
        #expect(controller.floatingSurface === reopened)
    }

    @Test
    func reopeningAfterOrdinaryFindReattachesRetainedResults() async throws {
        let fixture = try Fixture(files: [
            "CURRENT.md": "# Current\n",
            "NOTES.md": "The returning needle is here.\n",
        ])
        defer { fixture.remove() }

        let controller = try fixture.openController()
        defer { controller.close() }
        controller.activeStyleSheet = StyleSheet(
            theme: ThemeStore.shared.current,
            appearance: NSApp.effectiveAppearance,
            reduceMotionOverride: true
        )
        controller.showSiblingSearch()
        let firstInspector = try #require(controller.searchInspector)
        let results = try #require(controller.searchResults)

        controller.showFindBar(replace: false)
        #expect(await eventually { firstInspector.superview == nil })
        #expect(controller.searchResults === results)

        controller.showSiblingSearch()
        let reopenedInspector = try #require(controller.searchInspector)
        #expect(reopenedInspector !== firstInspector)
        #expect(results.isDescendant(of: reopenedInspector))
    }

    @Test
    func anAlreadyCancelledSearchReadsNoFiles() throws {
        let fixture = try Fixture(files: [
            "CURRENT.md": "# Current\n",
            "FIRST.md": "The cancellation needle is first.\n",
            "SECOND.md": "The cancellation needle is second.\n",
        ])
        defer { fixture.remove() }

        let hits = SiblingSearch.search(
            FindQuery(text: "needle"),
            in: [fixture.url(named: "FIRST.md"), fixture.url(named: "SECOND.md")],
            shouldCancel: { true }
        )

        #expect(hits.isEmpty)
    }

    @Test
    func ordinaryFindDoesNotStartSiblingSearch() async throws {
        let fixture = try Fixture(files: [
            "CURRENT.md": "# Current\n\nlocal needle\n",
            "NOTES.md": "sibling needle\n",
        ])
        defer { fixture.remove() }

        let controller = try fixture.openController()
        defer { controller.close() }
        controller.showFindBar(replace: false)
        let bar = try #require(controller.findBar)

        bar.setQueryText("needle")

        #expect(await eventually { controller.currentFindQuery.text == "needle" })
        #expect(controller.findSession.count == 1)
        #expect(!controller.siblingSearchActive)
        #expect(controller.searchResults == nil)
    }
}

private struct Fixture {
    let root: URL
    let current: URL

    init(files: [String: String]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("downright-sibling-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, contents) in files {
            try Data(contents.utf8).write(to: root.appendingPathComponent(name))
        }
        current = root.appendingPathComponent("CURRENT.md")
    }

    @MainActor
    func openController() throws -> DocumentWindowController {
        let controller = DocumentWindowController()
        try controller.open(current, mode: .live)
        return controller
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func url(named name: String) -> URL {
        root.appendingPathComponent(name)
    }

    func write(_ contents: String, to name: String) throws {
        try Data(contents.utf8).write(to: url(named: name))
    }

    func delete(_ name: String) throws {
        try FileManager.default.removeItem(at: url(named: name))
    }
}

private final class BlockingSearch: @unchecked Sendable {
    private let blockedQuery: String
    private let proceed = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var hasStarted = false
    private var hasBlocked = false
    private var hasReleased = false

    init(query: String) {
        blockedQuery = query
    }

    func run(
        _ query: FindQuery,
        _ urls: [URL],
        _ shouldCancel: @Sendable () -> Bool
    ) -> [SiblingSearch.Hit] {
        let shouldBlock = stateLock.withLock {
            guard query.text == blockedQuery, !hasBlocked else { return false }
            hasBlocked = true
            hasStarted = true
            return true
        }
        if shouldBlock {
            proceed.wait()
        }
        return SiblingSearch.search(query, in: urls, shouldCancel: shouldCancel)
    }

    @MainActor
    func waitUntilStarted() async -> Bool {
        await eventually {
            self.stateLock.withLock { self.hasStarted }
        }
    }

    func release() {
        let shouldSignal = stateLock.withLock {
            guard !hasReleased else { return false }
            hasReleased = true
            return true
        }
        if shouldSignal { proceed.signal() }
    }
}

private final class CountingSearch: @unchecked Sendable {
    private let lock = NSLock()
    private var searches = 0

    var count: Int {
        lock.withLock { searches }
    }

    func run(
        _ query: FindQuery,
        _ urls: [URL],
        _ shouldCancel: @Sendable () -> Bool
    ) -> [SiblingSearch.Hit] {
        lock.withLock { searches += 1 }
        return SiblingSearch.search(query, in: urls, shouldCancel: shouldCancel)
    }
}

@MainActor
private func drainSiblingSearchQueue(_ controller: DocumentWindowController) async {
    let queue = controller.siblingSearchQueue
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        queue.async {
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}

@MainActor
private func eventually(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
