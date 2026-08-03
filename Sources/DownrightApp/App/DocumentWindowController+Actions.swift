import AppKit
import MarkdownCore
import MarkdownRender

/// Small actions the context menus and delegates reach for.
extension DocumentWindowController {

    /// Follows a link to another markdown file in this same window (§7.1 —
    /// ⌘-click is what opens a new one).  Persists the current document's
    /// state first so its reading position survives the hop.
    func openInPlace(_ url: URL) {
        guard confirmPendingChangesBeforeClose(markDiscardForWindowClose: false) else { return }
        markdownDocument.close()
        do {
            try open(url, mode: mode)
            resetWorkspaceState(for: url)
        } catch {
            NSSound.beep()
        }
    }

    func updateBreadcrumbAndGutter() {
        refreshBreadcrumb()
        let current = markdownDocument.parsed.headings.lastIndex(where: {
            $0.range.location <= containerTextView.topVisibleOffset
        })
        outlinePanel?.currentHeadingIndex = current
        navigationPanel?.currentHeadingIndex = current
        let length = max(1, markdownDocument.parsed.length)
        let top = CGFloat(containerTextView.topVisibleOffset) / CGFloat(length)
        let activeContainer = documentPanes.first { $0.textView === containerTextView } ?? primaryContainer!
        let visibleHeight = activeContainer.scrollView.contentView.bounds.height
        let documentHeight = max(1, activeContainer.scrollView.documentView?.bounds.height ?? 1)
        let span = min(1, visibleHeight / documentHeight)
        densityGutterView.visibleRange = top...min(1, top + span)
        densityGutterView.readProgress = max(densityGutterView.readProgress, min(1, top + span))
        densityGutterView.outlineEntries = densityGutterView.outlineEntries.enumerated().map { index, entry in
            var updated = entry
            updated.isCurrent = index == current
            return updated
        }
    }

    // MARK: - Images

    func presentLightbox(source: String, caption: String?) {
        guard let window else { return }
        let url: URL? = source.contains("://")
            ? URL(string: source)
            : markdownDocument.url?.deletingLastPathComponent().appendingPathComponent(source)
        guard let url else { return }
        let present = {
            guard let image = NSImage(contentsOf: url) else { return }
            LightboxWindow(image: image, caption: caption).present(over: window)
        }
        if url.isFileURL {
            authorizeLocalEffect(.readLocalAsset, target: url, action: present)
        } else {
            authorizeExternalURL(url, action: present)
        }
    }

    func saveImageCopy(source: String) {
        guard let base = markdownDocument.url?.deletingLastPathComponent() else { return }
        let origin = base.appendingPathComponent(source).standardizedFileURL
        authorizeLocalEffect(.readLocalAsset, target: origin) {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = origin.lastPathComponent
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            do {
                try FileManager.default.copyItem(at: origin, to: destination)
            } catch {
                self.presentOperationError("Couldn’t save the image copy", error: error)
            }
        }
    }

    // MARK: - Code blocks

    private func codeBlockContents(for range: NSRange) -> String {
        let source = markdownDocument.text as NSString
        guard source.length > 0 else { return "" }
        if let block = markdownDocument.parsed.root.block(at: range.location),
           case .codeBlock(_, _, let contentRange) = block.content,
           contentRange.location >= 0,
           contentRange.upperBound <= source.length {
            return source.substring(with: contentRange)
        }

        guard range.location >= 0, range.upperBound <= source.length else { return "" }
        var lines = source.substring(with: range).components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeFirst()
        }
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeLast()
        }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    func saveCodeBlock(range: NSRange) {
        let code = codeBlockContents(for: range)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "snippet.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(code.utf8).write(to: url)
        } catch {
            presentOperationError("Couldn’t save the code block", error: error)
        }
    }

    /// Fenced code has no file of its own, so "open in editor" writes it to a
    /// temp file first — the point is to get it into the user's editor, not to
    /// pretend it came from somewhere.
    func openCodeBlockInEditor(range: NSRange) {
        let code = codeBlockContents(for: range)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Downright", isDirectory: true)

        var name = "snippet.txt"
        if let block = markdownDocument.parsed.root.block(at: range.location),
           case .codeBlock(let language, _, _) = block.content,
           let language {
            name = "snippet.\(CodeFileExtensions.extension(for: language))"
        }
        let url = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(code.utf8).write(to: url)
        } catch {
            presentOperationError("Couldn’t prepare the code block", error: error)
            return
        }
        authorizeLocalEffect(.launchPathOrEditor, target: url) {
            Preferences.shared.values.externalEditor.open(url, line: nil)
        }
    }

    // MARK: - Tables (§6.3)

    func tableInsertRow(_ tableRange: NSRange, at hitOffset: Int? = nil) {
        markdownDocument.ensureParsedCurrent()
        let row = rowIndex(in: tableRange, at: hitOffset)
        markdownDocument.apply(
            Restructure.insertRow(markdownDocument.parsed, tableRange: tableRange, afterRow: row),
            actionName: "Insert Row"
        )
    }

    func tableDeleteRow(_ tableRange: NSRange, at hitOffset: Int? = nil) {
        markdownDocument.ensureParsedCurrent()
        let row = rowIndex(in: tableRange, at: hitOffset)
        markdownDocument.apply(
            Restructure.deleteRow(markdownDocument.parsed, tableRange: tableRange, row: row),
            actionName: "Delete Row"
        )
    }

    func tableSetAlignment(_ tableRange: NSRange, _ alignment: TableAlignment, at hitOffset: Int? = nil) {
        markdownDocument.ensureParsedCurrent()
        let column = columnIndex(in: tableRange, at: hitOffset)
        markdownDocument.apply(
            Restructure.setColumnAlignment(
                markdownDocument.parsed, tableRange: tableRange, column: column, alignment: alignment
            ),
            actionName: "Set Column Alignment"
        )
    }

    private func rowIndex(in tableRange: NSRange, at hitOffset: Int? = nil) -> Int {
        guard let block = markdownDocument.parsed.root.block(at: tableRange.location),
              case .table(let data) = block.content
        else { return 0 }
        let offset = hitOffset ?? caretOffset()
        return data.rows.firstIndex { $0.range.touches(offset: offset) } ?? 0
    }

    private func columnIndex(in tableRange: NSRange, at hitOffset: Int? = nil) -> Int {
        guard let block = markdownDocument.parsed.root.block(at: tableRange.location),
              case .table(let data) = block.content
        else { return 0 }
        let offset = hitOffset ?? caretOffset()
        for row in data.rows {
            if let index = row.cells.firstIndex(where: { $0.range.touches(offset: offset) }) {
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
// The toolbar has two stable zones: document/source presentation at the
// optical centre and a compact action menu at the trailing edge. Find stays
// on its keyboard/menu path so the toolbar remains quiet.

extension DocumentWindowController: NSToolbarDelegate, NSMenuDelegate {
    static let modeItem = NSToolbarItem.Identifier("presentation-mode")
    private static let overflowItem = NSToolbarItem.Identifier("overflow")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            Self.modeItem,
            .flexibleSpace,
            Self.overflowItem,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Self.modeItem:
            let control = ToolbarPresentationControl { [weak self] selectedSegment in
                self?.toolbarModeChanged(selectedSegment)
            }
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = control
            item.label = "Presentation"
            item.toolTip = "Choose rendered Document or raw Source"
            item.visibilityPriority = .high
            return item

        case Self.overflowItem:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = ToolbarMenuButton(menu: makeOverflowMenu())
            item.label = "More"
            item.toolTip = "More document actions"
            item.visibilityPriority = .high
            return item
        default:
            return nil
        }
    }

    private func toolbarModeChanged(_ selectedSegment: Int) {
        let showSource = selectedSegment == 1
        let views = [primaryContainer?.textView, splitContainer?.textView].compactMap { $0 }
        for view in views {
            if showSource { view.focusEntireSource() }
            else { view.clearSourceFocus() }
        }
    }

    func refreshSourceFocusToolbar() {
        guard let toolbar = window?.toolbar else { return }
        let isActive = primaryContainer.textView.sourceFocus != .none
            || (splitContainer.map { $0.textView.sourceFocus != .none } ?? false)
        guard let item = toolbar.items.first(where: { $0.itemIdentifier == Self.modeItem }),
              let control = item.view as? ToolbarPresentationControl
        else { return }
        control.setSelectedSegment(isActive ? 1 : 0)
    }

    @objc private func toolbarShowTasks(_ sender: Any?) {
        if !navigationPinned { closeNavigationOverlay() }
        toggleTaskPanel()
    }

    @objc private func toolbarShowHistory(_ sender: Any?) {
        if !navigationPinned { closeNavigationOverlay() }
        showHistoryInspector()
    }

    private func makeOverflowMenu() -> NSMenu {
        let menu = NSMenu(title: "More")
        menu.delegate = self
        menu.addItem(menuItem(title: "Tasks", symbol: "checkmark.circle", action: #selector(toolbarShowTasks(_:))))
        menu.addItem(menuItem(title: "History", symbol: "clock.arrow.circlepath", action: #selector(toolbarShowHistory(_:))))
        menu.addItem(.separator())
        addCommands([.focusMode, .splitView, .pinWindow], to: menu)

        menu.addItem(.separator())
        let zoom = NSMenu(title: "Structural Zoom")
        addCommands([.zoomLevel1, .zoomLevel2, .zoomLevel3, .zoomLevel4, .zoomLevel5], to: zoom)
        zoom.addItem(.separator())
        addCommands([.zoomIn, .zoomOut], to: zoom)
        let zoomItem = NSMenuItem(title: "Structural Zoom", action: nil, keyEquivalent: "")
        zoomItem.image = NSImage(systemSymbolName: "text.magnifyingglass", accessibilityDescription: nil)
        zoomItem.submenu = zoom
        menu.addItem(zoomItem)

        menu.addItem(.separator())
        addCommands([.tidyDocument, .readerProfiles], to: menu)

        let export = NSMenu(title: "Export")
        addCommands([.exportPDF, .exportHTML, .exportSelectionAsImage], to: export)
        let exportItem = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        exportItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        exportItem.submenu = export
        menu.addItem(exportItem)
        return menu
    }

    private func addCommands(_ commands: [Command], to menu: NSMenu) {
        for command in commands {
            let item = MainMenu.commandItem(command)
            item.target = self
            menu.addItem(item)
        }
    }

    private func menuItem(title: String, symbol: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    func showHistoryInspector() {
        let inspector = historyInspector ?? HistoryInspectorView(styleSheet: activeStyleSheet)
        if historyInspector == nil {
            inspector.delegate = self
            historyInspector = inspector
        }
        inspector.versions = markdownDocument.versions()
        showInInspector(inspector, section: .history)
    }

    func refreshToolbarSelectionState() {
        refreshSourceFocusToolbar()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            switch item.title {
            case "Tasks": item.state = inspectorHost?.selectedSection == .tasks && !inspectorItem.isCollapsed ? .on : .off
            case "History": item.state = inspectorHost?.selectedSection == .history && !inspectorItem.isCollapsed ? .on : .off
            default: break
            }
        }
        updateCommandStates(in: menu)
    }

    private func updateCommandStates(in menu: NSMenu) {
        for item in menu.items {
            if let command = MainMenu.command(for: item) {
                item.state = commandState(command) ? .on : .off
            }
            if let submenu = item.submenu { updateCommandStates(in: submenu) }
        }
    }

    private func commandState(_ command: Command) -> Bool {
        switch command {
        case .focusMode: return isFocusModeEnabled
        case .splitView: return splitViewContainer != nil
        case .pinWindow: return isWindowPinned
        case .typewriterScrolling: return Preferences.shared.values.typewriterScrolling
        case .zoomLevel1: return containerTextView.zoomLevel == .h1
        case .zoomLevel2: return containerTextView.zoomLevel == .h2
        case .zoomLevel3: return containerTextView.zoomLevel == .headings
        case .zoomLevel4: return containerTextView.zoomLevel == .skeleton
        case .zoomLevel5: return containerTextView.zoomLevel == .everything
        default: return false
        }
    }
}
