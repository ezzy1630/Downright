import AppKit
import Testing
@testable import DownrightApp

@Suite(.serialized)
@MainActor
struct StartWindowTests {
    @Test
    func emptyStartWindowHasClearPrimaryActions() throws {
        let controller = StartWindowController(recents: [])
        defer { controller.close() }

        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()

        #expect(window.minSize == NSSize(width: 840, height: 540))
        #expect(window.titleVisibility == .hidden)
        #expect(window.contentView?.accessibilityLabel() == "Downright start window")
        #expect(window.initialFirstResponder != nil)

        let labels = buttons(in: window.contentView).compactMap { $0.accessibilityLabel() }
        #expect(labels.contains("Open…"))
        #expect(labels.contains("New Document…"))
    }

    @Test
    func recentRowsExposeFolderAndRelativeTime() throws {
        let recent = RecentDocument(
            path: "/tmp/notes/downright-start-window-test.md",
            displayName: "note",
            firstHeading: "Planning",
            lastOpened: Date(),
            wordCount: 1
        )
        let controller = StartWindowController(recents: [recent])
        defer { controller.close() }

        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()

        let recentButton = try #require(
            buttons(in: window.contentView).first { $0.accessibilityLabel() == "Open note" }
        )
        let value = try #require(recentButton.accessibilityValue() as? String)
        #expect(value.contains("Planning"))
        #expect(value.contains("notes"))
    }

    @Test
    func clickingARecentRowRoutesItsURLToTheOwner() throws {
        let recent = RecentDocument(
            path: "/tmp/downright-start-window-click.md",
            displayName: "note",
            firstHeading: "Planning",
            lastOpened: Date(),
            wordCount: 1
        )
        let controller = StartWindowController(recents: [recent])
        defer { controller.close() }

        var openedURL: URL?
        controller.onOpen = { openedURL = $0 }

        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let recentButton = try #require(
            buttons(in: window.contentView).first { $0.accessibilityLabel() == "Open note" }
        )
        recentButton.performClick(nil)

        #expect(openedURL?.path == recent.path)
    }

    @Test
    func primaryActionButtonsRouteOpenAndNewCallbacks() throws {
        let controller = StartWindowController(recents: [])
        defer { controller.close() }

        var openedPanel = false
        var createdDocument = false
        controller.onOpenPanel = { openedPanel = true }
        controller.onNew = { createdDocument = true }

        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let open = try #require(
            buttons(in: window.contentView).first { $0.accessibilityLabel() == "Open…" }
        )
        let create = try #require(
            buttons(in: window.contentView).first { $0.accessibilityLabel() == "New Document…" }
        )

        open.performClick(nil)
        create.performClick(nil)

        #expect(openedPanel)
        #expect(createdDocument)
    }

    @Test
    func reloadRecentsSwapsEmptyAndPopulatedStates() throws {
        let controller = StartWindowController(recents: [])
        defer { controller.close() }

        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(buttons(in: window.contentView).contains { $0.accessibilityLabel() == "Open note" } == false)

        let recent = RecentDocument(
            path: "/tmp/downright-start-window-reload.md",
            displayName: "note",
            firstHeading: "Planning",
            lastOpened: Date(),
            wordCount: 3
        )
        controller.reloadRecents([recent])
        window.contentView?.layoutSubtreeIfNeeded()

        #expect(buttons(in: window.contentView).contains { $0.accessibilityLabel() == "Open note" })

        controller.reloadRecents([])
        window.contentView?.layoutSubtreeIfNeeded()

        #expect(buttons(in: window.contentView).contains { $0.accessibilityLabel() == "Open note" } == false)
        let labels = buttons(in: window.contentView).compactMap { $0.accessibilityLabel() }
        #expect(labels.contains("Open…"))
        #expect(labels.contains("New Document…"))
    }

    @Test
    func reloadRecentsSkipsIdenticalPaths() throws {
        let recent = RecentDocument(
            path: "/tmp/downright-start-window-identical.md",
            displayName: "note",
            firstHeading: "Planning",
            lastOpened: Date(),
            wordCount: 2
        )
        let controller = StartWindowController(recents: [recent])
        defer { controller.close() }

        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let first = try #require(
            buttons(in: window.contentView).first { $0.accessibilityLabel() == "Open note" }
        )

        controller.reloadRecents([recent])
        window.contentView?.layoutSubtreeIfNeeded()
        let second = try #require(
            buttons(in: window.contentView).first { $0.accessibilityLabel() == "Open note" }
        )

        #expect(first === second)
    }

    @Test
    func reloadRecentsReplacesChangedSet() throws {
        let first = RecentDocument(
            path: "/tmp/downright-start-a.md",
            displayName: "alpha",
            firstHeading: "A",
            lastOpened: Date(),
            wordCount: 1
        )
        let second = RecentDocument(
            path: "/tmp/downright-start-b.md",
            displayName: "beta",
            firstHeading: "B",
            lastOpened: Date(),
            wordCount: 2
        )
        let controller = StartWindowController(recents: [first])
        defer { controller.close() }

        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(buttons(in: window.contentView).contains { $0.accessibilityLabel() == "Open alpha" })

        controller.reloadRecents([second])
        window.contentView?.layoutSubtreeIfNeeded()

        let labels = buttons(in: window.contentView).compactMap { $0.accessibilityLabel() }
        #expect(labels.contains("Open beta"))
        #expect(labels.contains("Open alpha") == false)
    }

    @Test
    func dismissClosesTheWindow() throws {
        let controller = StartWindowController(recents: [])
        _ = try #require(controller.window)

        var finished = false
        controller.dismiss(animated: false) {
            finished = true
        }
        #expect(finished)
        #expect(controller.window?.isVisible != true)
    }

    @Test
    func displaysUpToEightRecentRows() throws {
        let recents = (0..<10).map { index in
            RecentDocument(
                path: "/tmp/downright-start-limit-\(index).md",
                displayName: "doc\(index)",
                firstHeading: "H\(index)",
                lastOpened: Date().addingTimeInterval(TimeInterval(-index)),
                wordCount: index + 1
            )
        }
        let controller = StartWindowController(recents: Array(recents.prefix(8)))
        defer { controller.close() }

        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()

        let recentLabels = buttons(in: window.contentView)
            .compactMap { $0.accessibilityLabel() }
            .filter { $0.hasPrefix("Open doc") }
        #expect(recentLabels.count == 8)
    }

    private func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        let button = (view as? NSButton).map { [$0] } ?? []
        return button + view.subviews.flatMap { buttons(in: $0) }
    }
}
