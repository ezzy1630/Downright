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

        #expect(window.minSize == NSSize(width: 680, height: 500))
        #expect(window.maxSize == NSSize(width: 680, height: 500))
        #expect(!window.styleMask.contains(.resizable))
        #expect(window.titleVisibility == .hidden)
        #expect(window.contentView?.accessibilityLabel() == "Downright start window")
        #expect(window.initialFirstResponder != nil)

        let labels = buttons(in: window.contentView).compactMap { $0.accessibilityLabel() }
        #expect(labels.contains("Open File"))
        #expect(labels.contains("New Document"))
        // Ellipsis on the start screen reads as truncated text.
        #expect(labels.contains(where: { $0.contains("…") || $0.contains("...") }) == false)
    }

    @Test
    func primaryActionsShareACompactHorizontalAxis() throws {
        let controller = StartWindowController(recents: [])
        defer { controller.close() }

        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()

        let open = try #require(
            buttons(in: content).first { $0.accessibilityLabel() == "Open File" }
        )
        let create = try #require(
            buttons(in: content).first { $0.accessibilityLabel() == "New Document" }
        )
        let openCenter = open.convert(
            NSPoint(x: open.bounds.midX, y: open.bounds.midY),
            to: content
        )
        let createCenter = create.convert(
            NSPoint(x: create.bounds.midX, y: create.bounds.midY),
            to: content
        )

        #expect(abs(openCenter.y - createCenter.y) < 0.5)
        #expect(createCenter.x > openCenter.x)
        #expect(abs(open.frame.width - create.frame.width) < 0.5)
        #expect(abs(open.frame.width - 164) < 0.5)
    }

    @Test
    func recentRowsPreferHeadingOverMachineGeneratedNames() throws {
        let recent = RecentDocument(
            path: "/tmp/T/EditingKeyRepro-92C5F190-B66C-4E83-ABBF-5A58BB0EAFC3.md",
            displayName: "EditingKeyRepro-92C5F190-B66C-4E83-ABBF-5A58BB0EAFC3",
            firstHeading: "Editing Keys",
            lastOpened: Date(),
            wordCount: 12
        )
        let controller = StartWindowController(recents: [recent])
        defer { controller.close() }

        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()

        let labels = buttons(in: window.contentView).compactMap { $0.accessibilityLabel() }
        #expect(labels.contains("Open Editing Keys"))
        #expect(labels.contains(where: { $0.contains("92C5F190") }) == false)
    }

    @Test
    func duplicateTitlesAreDisambiguatedByFolder() throws {
        let first = RecentDocument(
            path: "/tmp/a/DownrightFresh.md",
            displayName: "DownrightFresh",
            firstHeading: "",
            lastOpened: Date(),
            wordCount: 1
        )
        let second = RecentDocument(
            path: "/tmp/b/DownrightFresh.md",
            displayName: "DownrightFresh",
            firstHeading: "",
            lastOpened: Date().addingTimeInterval(-10),
            wordCount: 1
        )
        let controller = StartWindowController(recents: [first, second])
        defer { controller.close() }

        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()

        let labels = buttons(in: window.contentView).compactMap { $0.accessibilityLabel() }
        #expect(labels.contains("Open DownrightFresh (a)"))
        #expect(labels.contains("Open DownrightFresh (b)"))
    }

    @Test
    func sameFolderDuplicatesGetUniqueFragments() throws {
        let first = RecentDocument(
            path: "/tmp/T/EditingKeyRepro-11111111-B66C-4E83-ABBF-5A58BB0EAFC3.md",
            displayName: "EditingKeyRepro-11111111-B66C-4E83-ABBF-5A58BB0EAFC3",
            firstHeading: "Title",
            lastOpened: Date(),
            wordCount: 1
        )
        let second = RecentDocument(
            path: "/tmp/T/EditingKeyRepro-22222222-B66C-4E83-ABBF-5A58BB0EAFC3.md",
            displayName: "EditingKeyRepro-22222222-B66C-4E83-ABBF-5A58BB0EAFC3",
            firstHeading: "Title",
            lastOpened: Date().addingTimeInterval(-10),
            wordCount: 1
        )
        let controller = StartWindowController(recents: [first, second])
        defer { controller.close() }

        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()

        let labels = buttons(in: window.contentView).compactMap { $0.accessibilityLabel() }
        #expect(labels.contains("Open EditingKeyRepro · 11111111"))
        #expect(labels.contains("Open EditingKeyRepro · 22222222"))
    }

    @Test
    func genericHeadingsFallBackToFileName() throws {
        let recent = RecentDocument(
            path: "/tmp/T/EditingKeyRepro-92C5F190-B66C-4E83-ABBF-5A58BB0EAFC3.md",
            displayName: "EditingKeyRepro-92C5F190-B66C-4E83-ABBF-5A58BB0EAFC3",
            firstHeading: "Title",
            lastOpened: Date(),
            wordCount: 12
        )
        let controller = StartWindowController(recents: [recent])
        defer { controller.close() }

        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()

        let labels = buttons(in: window.contentView).compactMap { $0.accessibilityLabel() }
        #expect(labels.contains("Open EditingKeyRepro"))
        #expect(labels.contains(where: { $0 == "Open Title" }) == false)
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
            buttons(in: window.contentView).first { $0.accessibilityLabel() == "Open File" }
        )
        let create = try #require(
            buttons(in: window.contentView).first { $0.accessibilityLabel() == "New Document" }
        )

        open.performClick(nil)
        create.performClick(nil)

        #expect(openedPanel)
        #expect(createdDocument)
    }

    @Test
    func recentPathCanonicalizationCollapsesSymlinks() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-recents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("notes.md")
        try Data("# Notes\n".utf8).write(to: target)
        let link = directory.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        // A file reached through a symlink must be the same recent identity as
        // the file itself — this is the contract `AppDelegate.open` uses to
        // keep one window per file (§9.3).
        let viaTarget = DocumentStateStore.canonicalPath(target.path)
        let viaLink = DocumentStateStore.canonicalPath(link.path)
        #expect(viaTarget == viaLink)
        #expect(viaTarget == DocumentStateStore.canonicalPath(viaTarget))
        #expect(viaLink == DocumentStateStore.canonicalPath(viaLink))

        // Distinct files must stay distinct even when they share a folder.
        let other = directory.appendingPathComponent("other.md")
        try Data("# Other\n".utf8).write(to: other)
        #expect(DocumentStateStore.canonicalPath(other.path) != viaTarget)
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
    }

    @Test
    func reloadUpdatesRecentMetadataWhenPathStaysTheSame() throws {
        let path = "/tmp/downright-start-window-metadata.md"
        let older = RecentDocument(
            path: path,
            displayName: "note",
            firstHeading: "Planning",
            lastOpened: Date().addingTimeInterval(-7_200),
            wordCount: 3
        )
        let controller = StartWindowController(recents: [older])
        defer { controller.close() }

        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let button = try #require(
            buttons(in: window.contentView).first { $0.accessibilityLabel() == "Open note" }
        )
        let before = String(describing: button.accessibilityValue())

        let newer = RecentDocument(
            path: path,
            displayName: "note",
            firstHeading: "Planning",
            lastOpened: Date(),
            wordCount: 3
        )
        controller.reloadRecents([newer])
        window.contentView?.layoutSubtreeIfNeeded()

        let refreshed = try #require(
            buttons(in: window.contentView).first { $0.accessibilityLabel() == "Open note" }
        )
        #expect(String(describing: refreshed.accessibilityValue()) != before)
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
    func primaryAndRecentButtonsAreEnabledAndFire() throws {
        let recent = RecentDocument(
            path: "/tmp/downright-start-enabled.md",
            displayName: "note",
            firstHeading: "",
            lastOpened: Date(),
            wordCount: 1
        )
        let controller = StartWindowController(recents: [recent])
        defer { controller.close() }

        var openedPanel = false
        var created = false
        var openedURL: URL?
        controller.onOpenPanel = { openedPanel = true }
        controller.onNew = { created = true }
        controller.onOpen = { openedURL = $0 }

        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()

        let all = buttons(in: window.contentView)
        for button in all {
            #expect(button.isEnabled)
        }

        let open = try #require(all.first { $0.accessibilityLabel() == "Open File" })
        let create = try #require(all.first { $0.accessibilityLabel() == "New Document" })
        let recentButton = try #require(all.first { $0.accessibilityLabel() == "Open note" })

        open.performClick(nil)
        create.performClick(nil)
        recentButton.performClick(nil)

        #expect(openedPanel)
        #expect(created)
        #expect(openedURL?.path == recent.path)
    }

    private func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        let button = (view as? NSButton).map { [$0] } ?? []
        return button + view.subviews.flatMap { buttons(in: $0) }
    }
}
