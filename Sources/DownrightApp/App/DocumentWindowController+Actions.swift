import AppKit
import MarkdownCore
import MarkdownRender

private final class PresentationSnapshotView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Small actions the context menus and delegates reach for.
extension DocumentWindowController {

    /// Follows a link to another markdown file in this same window (§7.1 —
    /// ⌘-click is what opens a new one).  Persists the current document's
    /// state first so its reading position survives the hop.
    func openInPlace(_ url: URL) {
        guard confirmPendingChangesBeforeClose(markDiscardForWindowClose: false) else { return }
        resetTransientChrome()
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
        let current = visibleHeadingIndex(at: containerTextView.topVisibleOffset)
        let length = max(1, markdownDocument.parsed.length)
        let top = CGFloat(containerTextView.topVisibleOffset) / CGFloat(length)
        let activeContainer = documentPanes.first { $0.textView === containerTextView } ?? primaryContainer!
        let visibleHeight = activeContainer.scrollView.contentView.bounds.height
        let documentHeight = max(1, activeContainer.scrollView.documentView?.bounds.height ?? 1)
        let span = min(1, visibleHeight / documentHeight)
        densityGutterView.visibleRange = top...min(1, top + span)
        densityGutterView.readProgress = max(densityGutterView.readProgress, min(1, top + span))
        // Only update outline entries / panel indices when the current heading
        // actually changes, to avoid creating a new array on every scroll frame.
        let previousCurrent = densityGutterView.outlineEntries.firstIndex(where: \.isCurrent)
        if previousCurrent != current {
            densityGutterView.outlineEntries = densityGutterView.outlineEntries.enumerated().map { index, entry in
                var updated = entry
                updated.isCurrent = index == current
                return updated
            }
        }
    }

    // MARK: - Activity cue (§12)

    func beginActivity() {
        activityIndicator.begin()
    }

    func endActivity() {
        activityIndicator.end()
    }

    // MARK: - Images

    func presentLightbox(source: String, caption: String?) {
        guard let window else { return }
        let localURL = LocalAssetPolicy.request(raw: source, documentURL: markdownDocument.url)?.url
        let remoteURL = URL(string: source).flatMap { url -> URL? in
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil else {
                return nil
            }
            return url
        }
        let url = localURL ?? remoteURL
        guard let url else { return }
        let present = {
            self.documentPanes.forEach { $0.textView.refreshLocalAssets() }
            guard let image = NSImage(contentsOf: url) else { return }
            LightboxWindow(
                image: image,
                caption: caption,
                reduceMotion: self.activeStyleSheet.reduceMotion,
                reduceTransparency: self.activeStyleSheet.reduceTransparency
            ).present(over: window)
        }
        if url.isFileURL {
            authorizeLocalEffect(.readLocalAsset, target: url, action: present)
        } else {
            authorizeRemoteAssetURL(url, action: present)
        }
    }

    func saveImageCopy(source: String) {
        guard let origin = LocalAssetPolicy.request(
            raw: source, documentURL: markdownDocument.url
        )?.url else { return }
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
// The toolbar has three stable zones: document identity at the leading edge,
// Document/Source at the optical centre, and a compact trailing cluster —
// activity, the panels a reader reaches for, task progress, overflow — that
// never nudges the centre rail.
//
// Find and Outline are in that cluster rather than inside `···` on purpose.
// The overflow was the only interactive control on the trailing edge, which
// put every panel in the app one unlabelled glyph and one menu away in a
// window with room for three more buttons.  `···` keeps what a reader reaches
// for occasionally; the two panels they reach for constantly are out where
// they can be seen and hit.
//
// The cluster ships as a single toolbar item, not five: AppKit pads every
// custom-view item by its own margin — a tax even a hidden 1pt placeholder
// pays — which scattered the row with uneven 14pt/42pt gaps and stretched
// the button plates to 36pt beside the ring's 30pt one.  `ToolbarTrailingCluster`
// owns the spacing instead, so the row reads as one tight unit against the
// trailing edge and the hidden spinner and pill cost nothing.

extension DocumentWindowController: NSToolbarDelegate, NSMenuDelegate, NSToolbarItemValidation {
    private static let identityItem = NSToolbarItem.Identifier("document-identity")
    static let modeItem = NSToolbarItem.Identifier("presentation-mode")
    private static let clusterItem = NSToolbarItem.Identifier("trailing-cluster")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.identityItem,
            .flexibleSpace,
            Self.modeItem,
            .flexibleSpace,
            Self.clusterItem,
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
        case Self.identityItem:
            guard let window else { return nil }
            let item = NSToolbarItem(itemIdentifier: identifier)
            let identity = ToolbarDocumentIdentityView(window: window)
            item.view = identity
            toolbarDocumentIdentityView = identity
            item.isBordered = false
            item.label = "Document"
            item.visibilityPriority = .high
            return item

        case Self.modeItem:
            let control = ToolbarPresentationControl { [weak self] selectedSegment in
                self?.toolbarModeChanged(selectedSegment)
            }
            control.isHidden = false
            toolbarPresentationControl = control
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = control
            item.isBordered = false
            item.label = "Document / Source"
            item.toolTip = "Switch between rendered Document and Source Focus"
            item.visibilityPriority = .high
            wireToolbarAction(
                item,
                title: "Toggle Document / Source",
                action: #selector(toolbarToggleSourceFocus(_:))
            )
            return item

        case Self.clusterItem:
            let findButton = ToolbarActionButton(
                symbol: "magnifyingglass", label: "Find",
                help: "Find in this document",
                target: self, action: #selector(toolbarShowFind(_:)),
                usesGlassSurface: true
            )
            findButton.styleSheet = activeStyleSheet
            toolbarFindButton = findButton
            let pill = updateStatusPill ?? UpdateStatusPill()
            updateStatusPill = pill
            // Held weakly because History and Context fly out of it: a morph
            // needs the seat of the control the reader actually clicked, and
            // for everything behind `···` that control is this button.
            let overflowButton = ToolbarMenuButton(menu: makeOverflowMenu())
            toolbarOverflowButton = overflowButton
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = ToolbarTrailingCluster(views: [
                activityIndicator,
                findButton,
                progressRing,
                pill,
                overflowButton,
            ])
            item.isBordered = false
            item.label = "Actions"
            // The ring is a permanent control — it shows an empty track rather
            // than hiding on a document with no tasks — so the cluster must
            // not be the first item the toolbar drops, and each view's own
            // tooltip is richer than a static one here.
            item.visibilityPriority = .high
            progressRing.onActivate = { [weak self] in
                self?.toolbarShowTasks(nil)
            }
            progressRing.onVisibilityChange = { [weak self] _ in
                self?.window?.toolbar?.validateVisibleItems()
            }
            activityIndicator.onVisibilityChange = { [weak self] _ in
                self?.window?.toolbar?.validateVisibleItems()
            }
            // When the window narrows enough to drop the cluster, the
            // toolbar's overflow chevron shows this in its place; the submenu
            // keeps the panels one reach away.
            let menuRep = NSMenuItem(title: "Actions", action: nil, keyEquivalent: "")
            let repMenu = NSMenu(title: "Actions")
            repMenu.addItem(menuItem(
                title: "Find", symbol: "magnifyingglass",
                action: #selector(toolbarShowFind(_:))
            ))
            repMenu.addItem(menuItem(
                title: "Tasks", symbol: "checkmark.circle",
                action: #selector(toolbarShowTasks(_:))
            ))
            repMenu.addItem(menuItem(
                title: "Check for Updates…", symbol: "arrow.triangle.2.circlepath",
                action: #selector(toolbarCheckForUpdates(_:))
            ))
            menuRep.submenu = repMenu
            item.menuFormRepresentation = menuRep
            return item

        default:
            return nil
        }
    }

    private func wireToolbarAction(
        _ item: NSToolbarItem,
        title: String,
        action: Selector
    ) {
        item.target = self
        item.action = action
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        item.menuFormRepresentation = menuItem
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        // Every toolbar control is always reachable: the mode switch, and the
        // cluster's panels, ring, pill, and menu.  The pill decides for
        // itself what a click opens, based on the update coordinator's state.
        true
    }

    private func toolbarModeChanged(_ selectedSegment: Int) {
        let showSource = selectedSegment == 1
        for pane in documentPanes {
            let outgoing = activeStyleSheet.reduceMotion ? nil : snapshot(of: pane)
            if showSource {
                pane.textView.focusEntireSource()
            } else {
                pane.textView.clearSourceFocus()
            }
            animatePresentationChange(in: pane, outgoing: outgoing, showSource: showSource)
        }
        refreshSourceFocusToolbar()
        // The mode control should change presentation, then return the user to
        // the editor. Leaving first responder on the toolbar makes an editable
        // Document mode feel inert until a second click.
        window?.makeFirstResponder(primaryContainer.textView)
    }

    private func snapshot(of view: NSView) -> NSImageView? {
        guard !view.bounds.isEmpty,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: representation)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(representation)
        let snapshot = PresentationSnapshotView(frame: view.bounds)
        snapshot.image = image
        snapshot.imageScaling = .scaleAxesIndependently
        snapshot.autoresizingMask = [.width, .height]
        snapshot.wantsLayer = true
        snapshot.layer?.masksToBounds = true
        view.addSubview(snapshot, positioned: .above, relativeTo: nil)
        return snapshot
    }

    /// Keep the viewport fixed while the two presentations pass each other.
    /// The direction communicates the state change; the short overlap hides
    /// TextKit's synchronous fragment rebuild without turning it into a flash.
    private func animatePresentationChange(
        in pane: MarkdownContainerView,
        outgoing: NSImageView?,
        showSource: Bool
    ) {
        guard !activeStyleSheet.reduceMotion, let outgoing,
              let incomingLayer = pane.textView.layer,
              let outgoingLayer = outgoing.layer
        else {
            outgoing?.removeFromSuperview()
            return
        }
        let direction: CGFloat = showSource ? 1 : -1
        pane.textView.wantsLayer = true
        let incomingTransform = CABasicAnimation(keyPath: "transform")
        incomingTransform.fromValue = CATransform3DMakeTranslation(12 * direction, 0, 0)
        incomingTransform.toValue = CATransform3DIdentity
        let incomingOpacity = CABasicAnimation(keyPath: "opacity")
        incomingOpacity.fromValue = 0
        incomingOpacity.toValue = 1
        let incoming = CAAnimationGroup()
        incoming.animations = [incomingTransform, incomingOpacity]
        incoming.duration = Motion.liquidSettle
        incoming.timingFunction = Motion.timing(.decelerate)
        incomingLayer.opacity = 1
        incomingLayer.transform = CATransform3DIdentity
        incomingLayer.add(incoming, forKey: "presentation-in")

        let outgoingTransform = CABasicAnimation(keyPath: "transform")
        outgoingTransform.fromValue = CATransform3DIdentity
        outgoingTransform.toValue = CATransform3DMakeTranslation(-9 * direction, 0, 0)
        let outgoingOpacity = CABasicAnimation(keyPath: "opacity")
        outgoingOpacity.fromValue = 1
        outgoingOpacity.toValue = 0
        let leaving = CAAnimationGroup()
        leaving.animations = [outgoingTransform, outgoingOpacity]
        leaving.duration = Motion.deliberate
        leaving.timingFunction = Motion.timing(.structural)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak outgoing] in outgoing?.removeFromSuperview() }
        outgoingLayer.opacity = 0
        outgoingLayer.add(leaving, forKey: "presentation-out")
        CATransaction.commit()
    }

    func refreshSourceFocusToolbar() {
        let isActive = primaryContainer.textView.sourceFocus != .none
            || (splitContainer.map { $0.textView.sourceFocus != .none } ?? false)
        toolbarPresentationControl?.isHidden = false
        toolbarPresentationControl?.setSelectedSegment(isActive ? 1 : 0)
    }

    @objc private func toolbarShowTasks(_ sender: Any?) {
        toggleTaskPanel()
    }

    @objc private func toolbarToggleSourceFocus(_ sender: Any?) {
        toolbarModeChanged(primaryContainer.textView.sourceFocus == .none ? 1 : 0)
    }

    @objc private func toolbarShowHistory(_ sender: Any?) {
        showHistoryInspector()
    }

    @objc private func toolbarShowFind(_ sender: Any?) {
        if findBar != nil, searchInspector == nil {
            dismissFindBar()
        } else {
            perform(.find)
        }
    }

    @objc private func toolbarCheckForUpdates(_ sender: Any?) {
        perform(.checkForUpdates)
    }

    private func makeOverflowMenu() -> NSMenu {
        let menu = NSMenu(title: "More")
        menu.delegate = self

        menu.addItem(sectionHeader("Panels"))
        menu.addItem(menuItem(title: "Tasks", symbol: "checkmark.circle", action: #selector(toolbarShowTasks(_:))))
        menu.addItem(menuItem(title: "History", symbol: "clock.arrow.circlepath", action: #selector(toolbarShowHistory(_:))))

        menu.addItem(sectionHeader("View"))
        addCommands([.sourceMode, .focusMode, .splitView, .pinWindow], to: menu)

        menu.addItem(sectionHeader("Document"))
        let zoom = NSMenu(title: "Document Detail")
        addCommands([.zoomLevel1, .zoomLevel2, .zoomLevel3, .zoomLevel4, .zoomLevel5], to: zoom)
        zoom.addItem(.separator())
        addCommands([.zoomIn, .zoomOut], to: zoom)
        let zoomItem = NSMenuItem(title: "Document Detail", action: nil, keyEquivalent: "")
        zoomItem.image = NSImage(systemSymbolName: "text.magnifyingglass", accessibilityDescription: nil)
        zoomItem.submenu = zoom
        menu.addItem(zoomItem)
        addCommands([.tidyDocument, .readerProfiles], to: menu)

        menu.addItem(sectionHeader("Share"))
        let export = NSMenu(title: "Export")
        addCommands([.exportPDF, .exportHTML, .exportSelectionAsImage], to: export)
        let exportItem = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        exportItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        exportItem.submenu = export
        menu.addItem(exportItem)
        return menu
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
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
        refreshToolbarPanelButtons()
    }

    /// Keeps the promoted panel buttons lit in step with the panels they open,
    /// the same way the task ring lights when its own panel is showing — a
    /// control that opens a panel and then says nothing about it is how a
    /// toolbar stops being trustworthy.
    func refreshToolbarPanelButtons() {
        toolbarFindButton?.styleSheet = activeStyleSheet
        toolbarFindButton?.isOn = findBar != nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        MainMenu.refreshKeyEquivalents(in: menu)
        for item in menu.items {
            switch item.title {
            case "Tasks": item.state = self.isTaskPanelFloating ? .on : .off
            case "History":
                item.state = floatingSurface != nil && inspectorHost?.selectedSection == .history
                    ? .on
                    : .off
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

    func commandState(_ command: Command) -> Bool {
        switch command {
        case .focusMode: return isFocusModeEnabled
        case .splitView: return splitViewContainer != nil
        case .pinWindow: return isWindowPinned
        case .typewriterScrolling: return Preferences.shared.values.typewriterScrolling
        case .statusBar: return Preferences.shared.values.showStatusBar
        case .sourceMode:
            return primaryContainer.textView.sourceFocus != .none
                || (splitContainer.map { $0.textView.sourceFocus != .none } ?? false)
        case .zoomLevel1: return containerTextView.zoomLevel == .h1
        case .zoomLevel2: return containerTextView.zoomLevel == .h2
        case .zoomLevel3: return containerTextView.zoomLevel == .headings
        case .zoomLevel4: return containerTextView.zoomLevel == .skeleton
        case .zoomLevel5: return containerTextView.zoomLevel == .everything
        default: return false
        }
    }
}
