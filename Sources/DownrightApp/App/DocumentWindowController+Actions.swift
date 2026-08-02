import AppKit
import MarkdownCore
import MarkdownRender

/// Small actions the context menus and delegates reach for.
extension DocumentWindowController {

    /// Follows a link to another markdown file in this same window (§7.1 —
    /// ⌘-click is what opens a new one).  Persists the current document's
    /// state first so its reading position survives the hop.
    func openInPlace(_ url: URL) {
        markdownDocument.close()
        do {
            try open(url, mode: mode)
        } catch {
            NSSound.beep()
        }
    }

    func updateBreadcrumbAndGutter() {
        refreshBreadcrumb()
        showTransientBreadcrumb()
        if let current = markdownDocument.parsed.headings.lastIndex(where: {
            $0.range.location <= containerTextView.topVisibleOffset
        }) {
            outlinePanel?.currentHeadingIndex = current
        }
        let length = max(1, markdownDocument.parsed.length)
        let top = CGFloat(containerTextView.topVisibleOffset) / CGFloat(length)
        let visibleHeight = primaryContainer.scrollView.contentView.bounds.height
        let documentHeight = max(1, primaryContainer.scrollView.documentView?.bounds.height ?? 1)
        let span = min(1, visibleHeight / documentHeight)
        densityGutterView.visibleRange = top...min(1, top + span)
        densityGutterView.readProgress = max(densityGutterView.readProgress, min(1, top + span))
        let current = markdownDocument.parsed.headings.lastIndex {
            $0.range.location <= containerTextView.topVisibleOffset
        }
        densityGutterView.outlineEntries = densityGutterView.outlineEntries.enumerated().map { index, entry in
            var updated = entry
            updated.isCurrent = index == current
            return updated
        }
    }

    private func showTransientBreadcrumb() {
        breadcrumbHideWorkItem?.cancel()
        PanelAnimation.run(reduceMotion: activeStyleSheet.reduceMotion, duration: 0.12) { _ in
            self.breadcrumbView.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            PanelAnimation.run(reduceMotion: self.activeStyleSheet.reduceMotion, duration: 0.09) { _ in
                self.breadcrumbView.animator().alphaValue = 0
            }
        }
        breadcrumbHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: - Images

    func presentLightbox(source: String, caption: String?) {
        guard let window else { return }
        let url: URL? = source.contains("://")
            ? URL(string: source)
            : markdownDocument.url?.deletingLastPathComponent().appendingPathComponent(source)
        guard let url, let image = NSImage(contentsOf: url) else { return }
        LightboxWindow(image: image, caption: caption).present(over: window)
    }

    func saveImageCopy(source: String) {
        guard let base = markdownDocument.url?.deletingLastPathComponent() else { return }
        let origin = base.appendingPathComponent(source)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = origin.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.copyItem(at: origin, to: destination)
    }

    // MARK: - Code blocks

    func saveCodeBlock(range: NSRange) {
        let code = (markdownDocument.text as NSString).substring(with: range)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "snippet.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(code.utf8).write(to: url)
    }

    /// Fenced code has no file of its own, so "open in editor" writes it to a
    /// temp file first — the point is to get it into the user's editor, not to
    /// pretend it came from somewhere.
    func openCodeBlockInEditor(range: NSRange) {
        let code = (markdownDocument.text as NSString).substring(with: range)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Downright", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var name = "snippet.txt"
        if let block = markdownDocument.parsed.root.block(at: range.location),
           case .codeBlock(let language, _, _) = block.content,
           let language {
            name = "snippet.\(CodeFileExtensions.extension(for: language))"
        }
        let url = directory.appendingPathComponent(name)
        try? Data(code.utf8).write(to: url)
        Preferences.shared.values.externalEditor.open(url, line: nil)
    }

    // MARK: - Tables (§6.3)

    func tableInsertRow(_ tableRange: NSRange) {
        let row = rowIndex(in: tableRange)
        markdownDocument.apply(
            Restructure.insertRow(markdownDocument.parsed, tableRange: tableRange, afterRow: row),
            actionName: "Insert Row"
        )
    }

    func tableDeleteRow(_ tableRange: NSRange) {
        let row = rowIndex(in: tableRange)
        markdownDocument.apply(
            Restructure.deleteRow(markdownDocument.parsed, tableRange: tableRange, row: row),
            actionName: "Delete Row"
        )
    }

    func tableSetAlignment(_ tableRange: NSRange, _ alignment: TableAlignment) {
        let column = columnIndex(in: tableRange)
        markdownDocument.apply(
            Restructure.setColumnAlignment(
                markdownDocument.parsed, tableRange: tableRange, column: column, alignment: alignment
            ),
            actionName: "Set Column Alignment"
        )
    }

    private func rowIndex(in tableRange: NSRange) -> Int {
        guard let block = markdownDocument.parsed.root.block(at: tableRange.location),
              case .table(let data) = block.content
        else { return 0 }
        let caret = caretOffset()
        return data.rows.firstIndex { $0.range.touches(offset: caret) } ?? 0
    }

    private func columnIndex(in tableRange: NSRange) -> Int {
        guard let block = markdownDocument.parsed.root.block(at: tableRange.location),
              case .table(let data) = block.content
        else { return 0 }
        let caret = caretOffset()
        for row in data.rows {
            if let index = row.cells.firstIndex(where: { $0.range.touches(offset: caret) }) {
                return index
            }
        }
        return 0
    }
}

/// File extension for a fence language, used when handing a snippet to an
/// external editor so its own syntax highlighting kicks in.
enum CodeFileExtensions {
    static func `extension`(for language: String) -> String {
        switch language.lowercased() {
        case "swift": return "swift"
        case "typescript", "ts": return "ts"
        case "tsx": return "tsx"
        case "javascript", "js": return "js"
        case "jsx": return "jsx"
        case "python", "py": return "py"
        case "rust", "rs": return "rs"
        case "go": return "go"
        case "ruby", "rb": return "rb"
        case "java": return "java"
        case "c": return "c"
        case "cpp", "c++": return "cpp"
        case "objc", "objective-c": return "m"
        case "bash", "sh", "shell", "zsh": return "sh"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "toml": return "toml"
        case "sql": return "sql"
        case "html": return "html"
        case "css": return "css"
        case "xml": return "xml"
        case "markdown", "md": return "md"
        default: return "txt"
        }
    }
}

// MARK: - Toolbar
//
// Auto-hiding in Read mode until the pointer moves (§11.4) is the window's job;
// the toolbar itself just carries the controls that stay useful in every mode.

extension DocumentWindowController: NSToolbarDelegate {
    private static let modeItem = NSToolbarItem.Identifier("mode")
    private static let zoomItem = NSToolbarItem.Identifier("zoom")
    private static let outlineItem = NSToolbarItem.Identifier("outline")
    private static let tasksItem = NSToolbarItem.Identifier("tasks")
    private static let siblingsItem = NSToolbarItem.Identifier("siblings")
    private static let findItem = NSToolbarItem.Identifier("find")
    private static let timelineItem = NSToolbarItem.Identifier("timeline")
    private static let overflowItem = NSToolbarItem.Identifier("overflow")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // §11.4: "No permanent sidebars, panels, or status bar."  The toolbar
        // is held to the same standard — two competing pill groups in the
        // centre read as an application, and this is meant to read as a
        // document.  Structural zoom keeps its `1`–`5` keys and the outline
        // panel's slider (§5.2); it does not need to sit on screen permanently,
        // so it stays available for customisation rather than shown by default.
        [
            .toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace,
            Self.modeItem, .flexibleSpace,
            Self.findItem, Self.tasksItem, Self.timelineItem, Self.overflowItem,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [Self.outlineItem, Self.siblingsItem, Self.zoomItem, .space, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Self.modeItem:
            let control = NSSegmentedControl(
                labels: RenderMode.allCases.map(\.title),
                trackingMode: .selectOne, target: self, action: #selector(modeSegmentChanged(_:))
            )
            control.selectedSegment = RenderMode.allCases.firstIndex(of: mode) ?? 0
            let symbols = ["book.pages", "pencil.and.outline", "chevron.left.forwardslash.chevron.right"]
            for index in 0..<min(control.segmentCount, symbols.count) {
                control.setImage(NSImage(systemSymbolName: symbols[index], accessibilityDescription: nil), forSegment: index)
            }
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = control
            item.label = "Mode"
            return item

        case Self.overflowItem:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = "More"
            item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")
            let menu = NSMenu(title: "More")
            for command in [Command.zoomIn, .zoomOut, .splitView, .exportHTML, .exportPDF, .tidyDocument] {
                let menuItem = MainMenu.commandItem(command)
                menuItem.target = self
                menu.addItem(menuItem)
            }
            item.menu = menu
            return item

        case Self.zoomItem:
            // The structural-zoom segmented control (§5.2).
            let control = NSSegmentedControl(
                labels: ["1", "2", "3", "4", "5"],
                trackingMode: .selectOne, target: self, action: #selector(zoomSegmentChanged(_:))
            )
            control.selectedSegment = containerTextView.zoomLevel.rawValue - 1
            for (index, level) in ZoomLevel.allCases.enumerated() {
                control.setToolTip(level.title, forSegment: index)
            }
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = control
            item.label = "Zoom"
            return item

        case Self.tasksItem:
            // A progress ring appears whenever a document has tasks (§8.5).
            let item = NSToolbarItem(itemIdentifier: identifier)
            progressRing.frame = NSRect(x: 0, y: 0, width: 22, height: 22)
            item.view = progressRing
            item.label = "Tasks"
            item.toolTip = "Tasks"
            item.action = #selector(toolbarTasks(_:))
            item.target = self
            return item

        default:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.target = self
            switch identifier {
            case Self.outlineItem:
                item.image = NSImage(systemSymbolName: "list.bullet.indent", accessibilityDescription: "Outline")
                item.label = "Outline"; item.action = #selector(toolbarOutline(_:))
            case Self.siblingsItem:
                item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Siblings")
                item.label = "Siblings"; item.action = #selector(toolbarSiblings(_:))
            case Self.findItem:
                item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Find")
                item.label = "Find"; item.action = #selector(toolbarFind(_:))
            case Self.timelineItem:
                item.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "History")
                item.label = "History"; item.action = #selector(toolbarTimeline(_:))
            default:
                return nil
            }
            item.isBordered = true
            return item
        }
    }

    @objc private func modeSegmentChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment < RenderMode.allCases.count else { return }
        applyMode(RenderMode.allCases[sender.selectedSegment])
    }

    @objc private func zoomSegmentChanged(_ sender: NSSegmentedControl) {
        guard let level = ZoomLevel(rawValue: sender.selectedSegment + 1) else { return }
        containerTextView.zoomLevel = level
        markdownDocument.state.zoomLevel = level
        outlinePanel?.zoomLevel = level
    }

    @objc private func toolbarOutline(_ sender: Any?) { toggleOutlinePanel() }
    @objc private func toolbarTasks(_ sender: Any?) { toggleTaskPanel() }
    @objc private func toolbarSiblings(_ sender: Any?) { toggleSiblingSidebar() }
    @objc private func toolbarFind(_ sender: Any?) { showFindBar(replace: false) }
    @objc private func toolbarTimeline(_ sender: Any?) { perform(.versionTimeline) }
}
