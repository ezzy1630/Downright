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

        #expect(window.minSize == NSSize(width: 860, height: 560))
        #expect(window.titleVisibility == .hidden)
        #expect(window.contentView?.accessibilityLabel() == "Downright start window")

        let labels = buttons(in: window.contentView).compactMap { $0.accessibilityLabel() }
        #expect(labels.contains("Open file"))
        #expect(labels.contains("New document"))
    }

    @Test
    func recentRowsExposeTheirDocumentIdentity() throws {
        let recent = RecentDocument(
            path: "/tmp/downright-start-window-test.md",
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
        #expect((recentButton.accessibilityValue() as? String) == "Planning  ·  1 word")
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

    private func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        let button = (view as? NSButton).map { [$0] } ?? []
        return button + view.subviews.flatMap { buttons(in: $0) }
    }
}
