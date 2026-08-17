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

        // Fixed size, and fixed to the layout's own constant — the assertion is
        // "this window does not resize", not "this window is 576pt tall".
        #expect(window.minSize == StartLayout.windowSize)
        #expect(window.maxSize == StartLayout.windowSize)
        #expect(!window.styleMask.contains(.resizable))
        #expect(window.titleVisibility == .hidden)
        #expect(window.contentView?.accessibilityLabel() == "Downright start window")
        #expect(window.initialFirstResponder != nil)
        #expect(window.contentView?.subviews.contains(where: { $0 is NSScrollView }) == false)

        let labels = buttons(in: window.contentView).compactMap { $0.accessibilityLabel() }
        #expect(labels.contains("Open File"))
        #expect(labels.contains("New Document"))
        let text = textFields(in: window.contentView).map(\.stringValue)
        #expect(text.contains("You can also drop a file anywhere") == false)
    }

    @Test
    func primaryActionsUseBalancedControlWells() throws {
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
        // Open and New are peer entry points. Keep their wells equal so the
        // longer title does not accidentally become the visual primary.
        #expect(abs(open.frame.width - StartLayout.actionButtonWidth) < 1)
        #expect(abs(create.frame.width - StartLayout.actionButtonWidth) < 1)
        #expect(abs(open.frame.width - create.frame.width) < 1)
        #expect(open.frame.height == StartLayout.buttonHeight)
        #expect(create.frame.height == StartLayout.buttonHeight)
    }

    @Test
    func openFileShortcutSitsCloseToItsLabel() throws {
        let controller = StartWindowController(recents: [])
        defer { controller.close() }

        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()

        let open = try #require(
            buttons(in: content).first { $0.accessibilityLabel() == "Open File" }
        )
        let labels = textFields(in: open)
        let title = try #require(labels.first { $0.stringValue == "Open File" })
        // Structural, not content-based: the only other text field in the
        // button is the shortcut, whatever the user has bound it to.
        let shortcut = try #require(labels.first { $0 !== title })

        // The label and the shortcut share the button's shell as a superview,
        // so a frame comparison in that space is the real rendered gap.
        // Matching the two buttons' widths used to stretch this from the
        // 12pt design constant to ~48pt of dead air.
        let gap = shortcut.frame.minX - title.frame.maxX
        // The compact keycap group keeps a deliberate 8pt optical gap after
        // the title without making the shortcut feel detached from its label.
        #expect(gap >= 8)
        #expect(gap <= 22)
        #expect(shortcut.frame.width >= 30)
        #expect(shortcut.frame.height >= 20)
        let shortcutInOpen = shortcut.convert(shortcut.bounds, to: open)
        #expect(shortcutInOpen.maxX <= open.bounds.maxX - 12)
    }

    @Test
    func tourButtonSizesToItsOwnLabel() throws {
        // The tour carries no shortcut, so its button must close up around its
        // label — the same content-hugging intrinsic the two action buttons
        // use, exercised through the no-shortcut path.
        let controller = StartWindowController(recents: [], guide: .secondary)
        defer { controller.close() }

        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()

        let tour = try #require(
            buttons(in: content).first { $0.accessibilityLabel() == "Take the Tour" }
        )
        #expect(abs(tour.frame.width - tour.intrinsicContentSize.width) < 1)
        #expect(tour.frame.width > 0)
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
    func recentRowsUseDocumentIconsAndContextMenuForClearing() throws {
        let recent = RecentDocument(
            path: "/tmp/downright-start-context.md",
            displayName: "note",
            firstHeading: "Planning",
            lastOpened: Date(),
            wordCount: 1
        )
        let controller = StartWindowController(recents: [recent])
        defer { controller.close() }

        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()

        let labels = buttons(in: window.contentView).compactMap { $0.accessibilityLabel() }
        #expect(labels.contains("Clear recent files") == false)

        let documentIcons = imageViews(in: window.contentView).filter {
            $0.accessibilityLabel() == "Markdown document"
        }
        #expect(documentIcons.count == 1)

        let menus = menus(in: window.contentView)
        #expect(menus.contains { $0.items.map(\.title) == ["Clear Recent Files…"] })
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
            lastOpened: Calendar.current.date(
                byAdding: .day, value: -1, to: Date()
            ) ?? Date().addingTimeInterval(-86_400),
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

    @Test
    func arrowKeysMoveFocusAcrossRecentRowsAndReturnOpens() throws {
        let first = RecentDocument(
            path: "/tmp/downright-kb-first.md",
            displayName: "note",
            firstHeading: "",
            lastOpened: Date(),
            wordCount: 1
        )
        let second = RecentDocument(
            path: "/tmp/downright-kb-second.md",
            displayName: "other",
            firstHeading: "",
            lastOpened: Date().addingTimeInterval(-10),
            wordCount: 1
        )
        let controller = StartWindowController(recents: [first, second])
        defer { controller.close() }

        var openedURL: URL?
        controller.onOpen = { openedURL = $0 }

        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()

        let open = try #require(
            buttons(in: content).first { $0.accessibilityLabel() == "Open File" }
        )
        window.makeFirstResponder(open)

        func key(_ keyCode: UInt16) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                keyCode: keyCode
            )!
        }

        func focusedLabel() -> String? {
            (window.firstResponder as? NSView)?.accessibilityLabel()
        }

        // Down lands on the first recent row.
        content.keyDown(with: key(125))
        #expect(focusedLabel() == "Open note")

        // Down again moves to the second row.
        content.keyDown(with: key(125))
        #expect(focusedLabel() == "Open other")

        // Up returns to the first.
        content.keyDown(with: key(126))
        #expect(focusedLabel() == "Open note")

        // Return opens the focused row.
        content.keyDown(with: key(36))
        #expect(openedURL?.path == first.path)
    }

    private func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        let button = (view as? NSButton).map { [$0] } ?? []
        return button + view.subviews.flatMap { buttons(in: $0) }
    }

    private func textFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        let direct = (view as? NSTextField).map { [$0] } ?? []
        return direct + view.subviews.flatMap { textFields(in: $0) }
    }

    private func imageViews(in view: NSView?) -> [NSImageView] {
        guard let view else { return [] }
        let direct = (view as? NSImageView).map { [$0] } ?? []
        return direct + view.subviews.flatMap { imageViews(in: $0) }
    }

    private func menus(in view: NSView?) -> [NSMenu] {
        guard let view else { return [] }
        let direct = view.menu.map { [$0] } ?? []
        return direct + view.subviews.flatMap { menus(in: $0) }
    }
}

// MARK: - Recent row content scent

/// The second line of a recent row is the app's argument in miniature: a folder
/// of agent output is a column of interchangeable names until something says
/// what each document is actually about.  These pin the cases where saying it
/// would be noise instead.
@Suite("Recent row subtitles")
@MainActor
struct RecentRowSubtitleTests {
    private func recent(
        path: String, name: String, heading: String
    ) -> RecentDocument {
        RecentDocument(
            path: path, displayName: name, firstHeading: heading,
            lastOpened: Date(timeIntervalSince1970: 1_000_000), wordCount: 100
        )
    }

    @Test("The heading leads, with the folder behind it")
    func headingAndFolder() {
        let row = recent(path: "/w/watchtest/notes.md", name: "notes", heading: "Agent output")
        #expect(RecentRowCopy.subtitle(for: row, title: "notes") == "Agent output  ·  watchtest")
    }

    @Test("A stale joined heading is repaired for the welcome row")
    func malformedJoinedHeading() {
        let row = recent(
            path: "/tmp/downright-live-selection-2.md",
            name: "downright-live-selection-2",
            heading: "ThiDownright renderer showcase"
        )
        #expect(
            RecentRowCopy.subtitle(for: row, title: "downright-live-selection-2")
                == "Downright renderer showcase  ·  tmp"
        )
    }

    @Test("Recent timestamps use calendar labels")
    func calendarTimestamps() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let older = calendar.date(byAdding: .day, value: -3, to: today)!

        #expect(RecentRowCopy.timestamp(for: RecentDocument(
            path: "/today.md", displayName: "today", firstHeading: "",
            lastOpened: today, wordCount: 0
        )) == "Today")
        #expect(
            RecentRowCopy.timestamp(for: RecentDocument(
                path: "/yesterday.md", displayName: "yesterday", firstHeading: "",
                lastOpened: yesterday, wordCount: 0
            )) == "Yesterday"
        )
        let olderLabel = RecentRowCopy.timestamp(for: RecentDocument(
            path: "/older.md", displayName: "older", firstHeading: "",
            lastOpened: older, wordCount: 0
        ))
        #expect(olderLabel.contains("ago") == false)
    }

    /// `README` in `Downright/` whose first heading is "Downright" would read
    /// "Downright · Downright".
    @Test("A heading that matches the folder is said once")
    func headingMatchingFolderIsNotRepeated() {
        let row = recent(path: "/w/Downright/README.md", name: "README", heading: "Downright")
        #expect(RecentRowCopy.subtitle(for: row, title: "README") == "Downright")
    }

    @Test("A heading that just restates the title gives way to the folder")
    func headingEchoingTitleFallsBackToFolder() {
        let row = recent(path: "/w/plans/Release Plan.md", name: "Release Plan", heading: "Release plan")
        #expect(RecentRowCopy.subtitle(for: row, title: "Release Plan") == "plans")
    }

    @Test("No heading leaves the folder")
    func noHeadingFallsBackToFolder() {
        let row = recent(path: "/w/scratchpad/unicode.md", name: "unicode", heading: "")
        #expect(RecentRowCopy.subtitle(for: row, title: "unicode") == "scratchpad")
    }

    @Test("Neither a heading nor a folder leaves the line empty rather than wrong")
    func nothingToSay() {
        let row = recent(path: "/notes.md", name: "notes", heading: "")
        #expect(RecentRowCopy.subtitle(for: row, title: "notes") == "")
    }

    /// Case and punctuation must not make two spellings of one phrase look like
    /// two different facts.
    @Test("Echo detection folds case and punctuation")
    func echoFolding() {
        #expect(RecentRowCopy.echoes("Release Plan", of: "release-plan"))
        #expect(RecentRowCopy.echoes("Setup", of: "Setup Guide"))
        #expect(!RecentRowCopy.echoes("Agent output", of: "notes"))
    }
}
