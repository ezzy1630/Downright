import AppKit
import MarkdownCore
import MarkdownRender

// MARK: - Text surface

extension DocumentWindowController: MarkdownTextViewDelegate {
    func markdownTextView(
        _ view: MarkdownTextView, didActivateLink destination: String,
        at range: NSRange, modifiers: NSEvent.ModifierFlags
    ) {
        // In-document anchor.
        if destination.hasPrefix("#") {
            let slug = String(destination.dropFirst())
            guard let heading = markdownDocument.parsed.headings.first(where: { $0.slug == slug }) else { return }
            jump(to: heading.range.location, label: heading.title)
            return
        }

        if destination.contains("://") {
            NSWorkspace.shared.open(URL(string: destination) ?? URL(fileURLWithPath: "/"))
            return
        }

        // A relative link to another markdown file opens in this app; ⌘-click
        // gives it a new window (§7.1).
        guard let base = markdownDocument.url?.deletingLastPathComponent() else { return }
        let target = base.appendingPathComponent(destination).standardizedFileURL
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        if DocumentTypes.isMarkdown(target.pathExtension) {
            if modifiers.contains(.command) {
                (NSApp.delegate as? AppDelegate)?.open(target)
            } else {
                openInPlace(target)
            }
        } else {
            NSWorkspace.shared.open(target)
        }
    }

    func markdownTextView(_ view: MarkdownTextView, didActivatePathToken token: PathToken, at range: NSRange) {
        guard let resolution = pathResolver?.resolve(token), resolution.exists, let url = resolution.url else { return }
        if resolution.isDirectory {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        } else if DocumentTypes.isMarkdown(url.pathExtension) {
            (NSApp.delegate as? AppDelegate)?.open(url)
        } else {
            Preferences.shared.values.externalEditor.open(url, line: token.line)
        }
    }

    func markdownTextView(_ view: MarkdownTextView, didToggleCheckboxAtMarkOffset offset: Int) {
        // Writes the file immediately (§7.1, §8.5).
        markdownDocument.toggleTask(atMarkOffset: offset)
    }

    func markdownTextView(
        _ view: MarkdownTextView, didActivateHeadingAnchor headingIndex: Int,
        modifiers: NSEvent.ModifierFlags
    ) {
        guard headingIndex < markdownDocument.parsed.headings.count else { return }
        let heading = markdownDocument.parsed.headings[headingIndex]
        if modifiers.contains(.option) {
            // ⌥-click folds the section (§7.1).
            if view.foldedHeadingSlugs.contains(heading.slug) {
                view.foldedHeadingSlugs.remove(heading.slug)
            } else {
                view.foldedHeadingSlugs.insert(heading.slug)
            }
            markdownDocument.state.foldedHeadings = view.foldedHeadingSlugs
        } else {
            copySectionLink()
        }
    }

    func markdownTextView(_ view: MarkdownTextView, pathExistsFor token: PathToken) -> Bool {
        guard Preferences.shared.values.resolvePathTokens else { return true }
        return pathResolver?.resolve(token).exists ?? false
    }

    func markdownTextViewDidChangeSelection(_ view: MarkdownTextView) {
        window?.toolbar?.validateVisibleItems()
        refreshVisualDebuggerIfVisible()
    }

    func markdownTextViewDidScroll(_ view: MarkdownTextView) {
        updateBreadcrumbAndGutter()
    }

    func markdownTextView(_ view: MarkdownTextView, didEdit range: NSRange, delta: Int) {
        // The document owns reparsing; the storage delegate already scheduled
        // it.  Change marks shift here so they keep pointing at the same text.
        markdownDocument.changes.adjust(forEditIn: range, delta: delta)
    }

    // MARK: Context menus (§7.1)

    func markdownTextView(_ view: MarkdownTextView, wantsContextMenuFor target: ContextTarget) -> NSMenu? {
        let menu = NSMenu()
        switch target.kind {
        case .heading(let index):
            add(.copySection, to: menu, title: "Copy Section as Markdown")
            menu.addItem(richTextSectionItem(index: index))
            add(.copySectionLink, to: menu)
            menu.addItem(.separator())
            add(.promoteHeading, to: menu)
            add(.demoteHeading, to: menu)
            menu.addItem(.separator())
            add(.foldSection, to: menu)
            add(.foldAll, to: menu, title: "Fold Siblings")
            add(.moveBlockUp, to: menu, title: "Move Section Up")
            add(.moveBlockDown, to: menu, title: "Move Section Down")

        case .codeBlock(let range):
            menu.addItem(actionItem("Copy Code") { [weak self] in
                self?.copy(range: range, flavour: .plain)
            })
            menu.addItem(actionItem("Save as File…") { [weak self] in
                self?.saveCodeBlock(range: range)
            })
            menu.addItem(actionItem("Open in Editor") { [weak self] in
                self?.openCodeBlockInEditor(range: range)
            })

        case .pathToken(let token):
            menu.addItem(actionItem("Open in Editor") { [weak self] in
                guard let resolution = self?.pathResolver?.resolve(token), let url = resolution.url else { return }
                Preferences.shared.values.externalEditor.open(url, line: token.line)
            })
            menu.addItem(actionItem("Reveal in Finder") { [weak self] in
                guard let url = self?.pathResolver?.resolve(token).url else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
            menu.addItem(actionItem("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(token.rawPath, forType: .string)
            })

        case .image(let source):
            menu.addItem(actionItem("Open in Lightbox") { [weak self] in
                self?.presentLightbox(source: source, caption: nil)
            })
            menu.addItem(actionItem("Save a Copy…") { [weak self] in self?.saveImageCopy(source: source) })
            menu.addItem(actionItem("Reveal in Finder") { [weak self] in
                guard let base = self?.markdownDocument.url?.deletingLastPathComponent() else { return }
                NSWorkspace.shared.activateFileViewerSelecting([base.appendingPathComponent(source)])
            })

        case .link(let destination):
            menu.addItem(actionItem("Open Link") { [weak self] in
                guard let self else { return }
                self.markdownTextView(view, didActivateLink: destination, at: target.sourceRange, modifiers: [])
            })
            menu.addItem(actionItem("Copy Target") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(destination, forType: .string)
            })

        case .table(let range):
            menu.addItem(actionItem("Insert Row") { [weak self] in self?.tableInsertRow(range) })
            menu.addItem(actionItem("Delete Row") { [weak self] in self?.tableDeleteRow(range) })
            menu.addItem(.separator())
            for alignment in [TableAlignment.left, .center, .right] {
                menu.addItem(actionItem("Align Column \(alignment.rawValue.capitalized)") { [weak self] in
                    self?.tableSetAlignment(range, alignment)
                })
            }
            menu.addItem(actionItem("Realign Source") { [weak self] in
                guard let self else { return }
                self.markdownDocument.ensureParsedCurrent()
                self.markdownDocument.apply(
                    Restructure.realignTable(self.markdownDocument.parsed, tableRange: range),
                    actionName: "Realign Table"
                )
            })

        case .selection:
            add(.copyAsMarkdown, to: menu)
            add(.copyAsRichText, to: menu)
            add(.copyAsPlainText, to: menu)
            menu.addItem(.separator())
            add(.convertToBulletList, to: menu)
            add(.convertToNumberedList, to: menu)
            add(.convertToTaskList, to: menu)
            add(.convertToBlockquote, to: menu)

        case .plain:
            add(.toggleReadLive, to: menu)
            add(.tidyDocument, to: menu)
            add(.outlineQuickOpen, to: menu)
        }
        return menu.items.isEmpty ? nil : menu
    }

    private func add(_ command: Command, to menu: NSMenu, title: String? = nil) {
        let item = MainMenu.commandItem(command)
        if let title { item.title = title }
        item.target = self
        menu.addItem(item)
    }

    private func richTextSectionItem(index: Int) -> NSMenuItem {
        actionItem("Copy Section as Rich Text") { [weak self] in
            guard let self, index < self.markdownDocument.parsed.headings.count else { return }
            self.copy(range: self.markdownDocument.parsed.headings[index].sectionRange, flavour: .richText)
        }
    }

    private func actionItem(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(BlockActionTarget.run(_:)), keyEquivalent: "")
        let target = BlockActionTarget(handler: handler)
        item.target = target
        item.representedObject = target  // keeps the target alive with the item
        return item
    }
}

/// Menu items hold their target weakly, so a closure-backed item needs
/// something to own the closure for as long as the menu exists.
final class BlockActionTarget: NSObject {
    private let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
    @objc func run(_ sender: Any?) { handler() }
}

// MARK: - Panels

extension DocumentWindowController: OutlinePanelDelegate {
    func outlinePanel(_ panel: OutlinePanelView, didSelectHeadingAt index: Int) {
        guard index < markdownDocument.parsed.headings.count else { return }
        let heading = markdownDocument.parsed.headings[index]
        jump(to: heading.range.location, label: heading.title)
    }

    func outlinePanel(_ panel: OutlinePanelView, didMoveHeadingAt index: Int, before targetIndex: Int) {
        // Moves the heading and everything beneath it (§7.1).
        markdownDocument.ensureParsedCurrent()
        let edits = Restructure.moveSection(markdownDocument.parsed, headingIndex: index, before: targetIndex)
        markdownDocument.apply(edits, actionName: "Move Section")
    }

    func outlinePanel(_ panel: OutlinePanelView, didToggleFoldAt index: Int) {
        markdownDocument.ensureParsedCurrent()
        guard index < markdownDocument.parsed.headings.count else { return }
        let slug = markdownDocument.parsed.headings[index].slug
        if containerTextView.foldedHeadingSlugs.contains(slug) {
            containerTextView.foldedHeadingSlugs.remove(slug)
        } else {
            containerTextView.foldedHeadingSlugs.insert(slug)
        }
        markdownDocument.state.foldedHeadings = containerTextView.foldedHeadingSlugs
    }

    func outlinePanel(_ panel: OutlinePanelView, didChangeZoomLevel level: ZoomLevel) {
        containerTextView.zoomLevel = level
        markdownDocument.state.zoomLevel = level
    }
}

extension DocumentWindowController: TaskPanelDelegate {
    func taskPanel(_ panel: TaskPanelView, didToggleTaskAt markOffset: Int) {
        markdownDocument.ensureParsedCurrent()
        markdownDocument.toggleTask(atMarkOffset: markOffset)
    }

    func taskPanel(_ panel: TaskPanelView, didSelectTaskAt contentOffset: Int) {
        jump(to: contentOffset, label: "Task")
    }
}

extension DocumentWindowController: SiblingSidebarDelegate {
    func siblingSidebar(_ sidebar: SiblingSidebarView, didSelect url: URL, inNewWindow: Bool) {
        if inNewWindow {
            (NSApp.delegate as? AppDelegate)?.open(url)
        } else {
            openInPlace(url)
        }
    }
}

extension DocumentWindowController: DensityGutterDelegate {
    func densityGutter(_ gutter: DensityGutterView, didRequestScrollToFraction fraction: CGFloat) {
        let offset = Int(fraction * CGFloat(markdownDocument.parsed.length))
        containerTextView.scroll(toOffset: offset, position: .top, animated: false)
        updateBreadcrumbAndGutter()
    }

    func densityGutter(
        _ gutter: DensityGutterView, previewAtFraction fraction: CGFloat
    ) -> (title: String, snippet: String)? {
        let offset = Int(fraction * CGFloat(markdownDocument.parsed.length))
        guard let heading = markdownDocument.parsed.headings.last(where: { $0.range.location <= offset }) else {
            return ("Top", String(markdownDocument.parsed.substring(NSRange(location: 0, length: min(120, markdownDocument.parsed.length)))))
        }
        let snippetLength = min(160, max(0, markdownDocument.parsed.length - offset))
        return (heading.title, markdownDocument.parsed.substring(NSRange(location: offset, length: snippetLength)))
    }
}

extension DocumentWindowController: BreadcrumbDelegate {
    func breadcrumb(_ view: BreadcrumbView, didSelectHeadingAt index: Int) {
        guard index < markdownDocument.parsed.headings.count else { return }
        jump(to: markdownDocument.parsed.headings[index].range.location, label: markdownDocument.parsed.headings[index].title)
    }
}

extension DocumentWindowController: FindBarDelegate {
    func findBar(_ bar: FindBarView, didChange query: FindQuery) { runFind(query) }

    func findBar(_ bar: FindBarView, didRequestAdvance forward: Bool) { advanceFind(forward: forward) }

    func findBar(_ bar: FindBarView, didRequestReplace replacement: String, all: Bool) {
        if all {
            let edits = FindEngine.replaceAllEdits(in: markdownDocument.text, query: currentFindQuery, template: replacement)
            markdownDocument.apply(edits, actionName: "Replace All")
        } else if let match = findSession.currentMatch {
            let text = FindEngine.replacement(
                for: match, in: markdownDocument.text, query: currentFindQuery, template: replacement
            )
            markdownDocument.replace(match, with: text, actionName: "Replace")
        }
        runFind(currentFindQuery)
    }

    func findBarDidRequestClose(_ bar: FindBarView) { dismissFindBar() }
}

extension DocumentWindowController: ConflictBarDelegate {
    func conflictBarDidRequestReview(_ bar: ConflictBarView) {
        guard let conflict = pendingConflict, let url = markdownDocument.url else { return }
        let controller = CompareWindowController(
            leftText: markdownDocument.text, leftTitle: "Yours",
            rightText: conflict.incomingText, rightTitle: "On disk",
            documentURL: url
        )
        controller.showWindow(nil)
        retainTimeline(controller)
    }

    func conflictBarDidRequestKeepMine(_ bar: ConflictBarView) {
        markdownDocument.resolveConflictKeepingMine()
        dismissConflictBar()
    }

    func conflictBarDidRequestTakeTheirs(_ bar: ConflictBarView) {
        guard let conflict = pendingConflict else { return }
        markdownDocument.resolveConflictTakingTheirs(conflict)
        dismissConflictBar()
    }

    func conflictBarDidRequestDismiss(_ bar: ConflictBarView) { dismissConflictBar() }
}

extension DocumentWindowController: ChangeSummaryBarDelegate {
    func changeSummaryBar(_ bar: ChangeSummaryBarView, didRequestJump forward: Bool) {
        perform(forward ? .nextChange : .previousChange)
    }

    func changeSummaryBarDidRequestDismiss(_ bar: ChangeSummaryBarView) { dismissChangeSummary() }
}

extension DocumentWindowController: TidySheetDelegate {
    func tidySheet(_ sheet: TidySheetView, didApply edits: [TextEdit]) {
        markdownDocument.apply(edits, actionName: "Tidy Document")
        closeTidySheet()
    }

    func tidySheetDidCancel(_ sheet: TidySheetView) { closeTidySheet() }

    private func closeTidySheet() {
        guard let sheetWindow = tidySheetWindow else { return }
        window?.endSheet(sheetWindow)
        tidySheetWindow = nil
    }
}

extension DocumentWindowController: SearchResultsDelegate {
    func searchResults(_ view: SearchResultsPanelView, didSelect hit: SiblingSearch.Hit) {
        if hit.url.path == markdownDocument.url?.path {
            jump(to: hit.range.location, label: "Search hit")
        } else if let controller = (NSApp.delegate as? AppDelegate)?.open(hit.url) {
            controller.jump(to: hit.range.location, label: "Search hit")
        }
    }
}
