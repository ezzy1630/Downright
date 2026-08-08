import AppKit
import MarkdownCore
import MarkdownRender

// MARK: - Text surface

extension DocumentWindowController: MarkdownTextViewDelegate {
    func markdownTextView(_ view: MarkdownTextView, didRequestTextSizeSteps steps: Int) {
        guard steps != 0 else { return }
        adjustTextSize(by: CGFloat(steps))
    }

    func markdownTextViewDidRequestSmartTextZoom(_ view: MarkdownTextView) {
        Preferences.shared.update {
            $0.textSizeAdjustment = $0.textSizeAdjustment == 0 ? 3 : 0
        }
    }
    func markdownTextView(
        _ view: MarkdownTextView, didRequestHeadingLevel level: Int?, headingIndex: Int
    ) {
        markdownDocument.ensureParsedCurrent()
        guard markdownDocument.parsed.headings.indices.contains(headingIndex) else { return }
        if let level {
            let edits = Restructure.setHeadingLevel(
                markdownDocument.parsed, headingIndex: headingIndex, level: level
            )
            markdownDocument.apply(edits, actionName: "Set Heading \(level)")
            return
        }
        let heading = markdownDocument.parsed.headings[headingIndex]
        let line = markdownDocument.parsed.range(ofLine: markdownDocument.parsed.line(at: heading.range.location))
        let source = markdownDocument.parsed.substring(line)
        let indent = source.prefix { $0 == " " || $0 == "\t" }
        let hashes = source.dropFirst(indent.count).prefix { $0 == "#" }
        guard !hashes.isEmpty else { return }
        markdownDocument.apply([
            TextEdit(
                range: NSRange(
                    location: line.location + indent.utf16.count,
                    length: hashes.utf16.count + 1
                ),
                replacement: "",
                summary: "Heading to body text"
            ),
        ], actionName: "Body Text")
    }
    func markdownTextView(_ view: MarkdownTextView, didActivateImage source: String, at range: NSRange) {
        presentLightbox(source: source, caption: nil)
    }

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
            guard let url = URL(string: destination) else { return }
            authorizeExternalURL(url) { NSWorkspace.shared.open(url) }
            return
        }

        // A relative link opens in place; ⌘-click keeps the current document
        // and opens the target in the active native tab group.
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
            authorizeLocalEffect(.launchPathOrEditor, target: target) {
                NSWorkspace.shared.open(target)
            }
        }
    }

    func markdownTextView(_ view: MarkdownTextView, didActivatePathToken token: PathToken, at range: NSRange) {
        guard let resolution = pathResolver?.resolve(token), resolution.exists, let url = resolution.url else { return }
        if resolution.isDirectory {
            authorizeLocalEffect(.launchPathOrEditor, target: url) {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
            }
        } else if DocumentTypes.isMarkdown(url.pathExtension) {
            (NSApp.delegate as? AppDelegate)?.open(url)
        } else {
            authorizeLocalEffect(.launchPathOrEditor, target: url) {
                Preferences.shared.values.externalEditor.open(url, line: token.line)
            }
        }
    }

    func markdownTextView(_ view: MarkdownTextView, didToggleCheckboxAtMarkOffset offset: Int) {
        // Writes the file immediately (§7.1, §8.5).
        primaryContainer.textView.preserveViewportOnNextDocumentUpdate()
        splitContainer?.textView.preserveViewportOnNextDocumentUpdate()
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
            var folds = view.foldedHeadingSlugs
            if folds.contains(heading.slug) { folds.remove(heading.slug) }
            else { folds.insert(heading.slug) }
            setSharedFolds(folds, from: view)
        } else {
            copySectionLink(index: headingIndex)
        }
    }

    func markdownTextView(_ view: MarkdownTextView, didNavigateTo destination: Int) {
        // A footnote jump is a navigation like any other, so Back has to undo
        // it — landing at the bottom of a long document used to be a one-way
        // trip.
        recordJump(to: destination, label: "Footnote")
    }

    func markdownTextView(_ view: MarkdownTextView, pathExistsFor token: PathToken) -> Bool {
        guard Preferences.shared.values.resolvePathTokens else { return true }
        return pathResolver?.resolve(token).exists ?? false
    }

    func markdownTextViewDidChangeSelection(_ view: MarkdownTextView) {
        synchronizePanes(from: view)
        let selection = view.sourceSelectedRange
        markdownDocument.state.selectionLocation = selection.location
        markdownDocument.state.selectionLength = selection.length
        updateFocusDimmingViews()
        window?.toolbar?.validateVisibleItems()
        refreshVisualDebuggerIfVisible()
        // Push cursor position to the status bar.
        let text = markdownDocument.text as NSString
        let offset = selection.location
        let line = max(1, text.substring(to: min(offset, text.length)).components(separatedBy: "\n").count)
        let lineStart = text.rangeOfCharacter(
            from: .newlines, options: .backwards,
            range: NSRange(location: 0, length: min(offset, text.length))
        ).location
        let column = max(1, offset - (lineStart == NSNotFound ? 0 : lineStart))
        statusBarView.cursorPosition = (line: line, column: column)
    }

    func markdownTextViewDidScroll(_ view: MarkdownTextView) {
        synchronizePanes(from: view)
        updateBreadcrumbAndGutter()
        noteVisibleChangeMarks()
        let visible = view.enclosingScrollView?.documentVisibleRect ?? view.visibleRect
        let current = markdownDocument.parsed.headings.last {
            $0.range.location <= view.topVisibleOffset
        }
        if let current,
           let headingRect = view.rect(forOffset: current.range.location),
           headingRect.maxY < visible.minY + 1 {
            breadcrumbView.showCurrentSection()
        } else {
            breadcrumbView.hideCurrentSection()
        }
        updateFocusDimmingViews()
    }

    func markdownTextView(_ view: MarkdownTextView, didChangeSourceFocus focus: SourceFocus) {
        synchronizePanes(from: view)
        mode = view.mode.normalizedForEditing
        markdownDocument.state.mode = .live
        refreshSourceFocusToolbar()
        primaryContainer.needsLayout = true
        splitContainer?.needsLayout = true
    }

    func markdownTextView(_ view: MarkdownTextView, didEdit range: NSRange, delta: Int) {
        // The document owns reparsing; the storage delegate already scheduled
        // it.  Change marks shift here so they keep pointing at the same text.
        markdownDocument.changes.adjust(forEditIn: range, delta: delta)
        scheduleFindRefresh()
    }

    // MARK: Context menus (§7.1)

    func markdownTextView(_ view: MarkdownTextView, wantsContextMenuFor target: ContextTarget) -> NSMenu? {
        let menu = NSMenu()
        switch target.kind {
        case .heading(let index):
            menu.addItem(editMarkdownItem(
                view: view,
                range: markdownDocument.parsed.headings[index].range
            ))
            menu.addItem(.separator())
            add(.copySection, to: menu)
            menu.addItem(richTextSectionItem(index: index))
            add(.copySectionLink, to: menu)
            menu.addItem(.separator())
            add(.promoteHeading, to: menu)
            add(.demoteHeading, to: menu)
            menu.addItem(.separator())
            add(.foldSection, to: menu)
            add(.foldAll, to: menu)
            add(.moveBlockUp, to: menu)
            add(.moveBlockDown, to: menu)

        case .codeBlock(let range):
            menu.addItem(editMarkdownItem(view: view, range: range))
            menu.addItem(.separator())
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
            menu.addItem(editMarkdownItem(view: view, range: target.sourceRange))
            menu.addItem(.separator())
            menu.addItem(actionItem("Open in Editor") { [weak self] in
                guard let self, let resolution = self.pathResolver?.resolve(token), let url = resolution.url else { return }
                self.authorizeLocalEffect(.launchPathOrEditor, target: url) {
                    Preferences.shared.values.externalEditor.open(url, line: token.line)
                }
            })
            menu.addItem(actionItem("Reveal in Finder") { [weak self] in
                guard let self, let url = self.pathResolver?.resolve(token).url else { return }
                self.authorizeLocalEffect(.launchPathOrEditor, target: url) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            })
            menu.addItem(actionItem("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(token.rawPath, forType: .string)
            })

        case .image(let source):
            menu.addItem(editMarkdownItem(view: view, range: target.sourceRange))
            menu.addItem(.separator())
            menu.addItem(actionItem("Open in Lightbox") { [weak self] in
                self?.presentLightbox(source: source, caption: nil)
            })
            menu.addItem(actionItem("Save a Copy…") { [weak self] in self?.saveImageCopy(source: source) })
            menu.addItem(actionItem("Reveal in Finder") { [weak self] in
                guard let self, let base = self.markdownDocument.url?.deletingLastPathComponent() else { return }
                let url = base.appendingPathComponent(source).standardizedFileURL
                self.authorizeLocalEffect(.launchPathOrEditor, target: url) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            })

        case .link(let destination):
            menu.addItem(editMarkdownItem(view: view, range: target.sourceRange))
            menu.addItem(.separator())
            menu.addItem(actionItem("Open Link") { [weak self] in
                guard let self else { return }
                self.markdownTextView(view, didActivateLink: destination, at: target.sourceRange, modifiers: [])
            })
            menu.addItem(actionItem("Copy Target") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(destination, forType: .string)
            })

        case .table(let range):
            menu.addItem(editMarkdownItem(view: view, range: range))
            menu.addItem(.separator())
            menu.addItem(actionItem("Insert Row") { [weak self] in
                self?.tableInsertRow(range, at: target.hitOffset)
            })
            menu.addItem(actionItem("Delete Row") { [weak self] in
                self?.tableDeleteRow(range, at: target.hitOffset)
            })
            menu.addItem(.separator())
            for alignment in [TableAlignment.left, .center, .right] {
                menu.addItem(actionItem("Align Column \(alignment.rawValue.capitalized)") { [weak self] in
                    self?.tableSetAlignment(range, alignment, at: target.hitOffset)
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
            let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
            copy.target = view
            menu.addItem(copy)
            menu.addItem(editMarkdownItem(view: view, range: target.sourceRange))
            menu.addItem(.separator())
            add(.copyAsMarkdown, to: menu)
            add(.copyAsRichText, to: menu)
            add(.copyAsPlainText, to: menu)
            menu.addItem(.separator())
            menu.addItem(actionItem("Add Comment…") { [weak self] in
                self?.presentAddReview(kind: .comment)
            })
            menu.addItem(actionItem("Suggest Replacement…") { [weak self] in
                self?.presentAddReview(kind: .suggestion)
            })
            add(.speakDocument, to: menu)
            menu.addItem(.separator())
            add(.convertToBulletList, to: menu)
            add(.convertToNumberedList, to: menu)
            add(.convertToTaskList, to: menu)
            add(.convertToBlockquote, to: menu)

        case .plain:
            let blockRange = markdownDocument.parsed.root.block(at: target.sourceRange.location)?.range
                ?? target.sourceRange
            menu.addItem(editMarkdownItem(view: view, range: blockRange))
            menu.addItem(.separator())
            add(.tidyDocument, to: menu)
        }
        return menu.items.isEmpty ? nil : menu
    }

    private func add(_ command: Command, to menu: NSMenu, title: String? = nil) {
        let item = MainMenu.commandItem(command)
        if let title { item.title = title }
        item.target = self
        menu.addItem(item)
    }

    private func editMarkdownItem(view: MarkdownTextView, range: NSRange) -> NSMenuItem {
        actionItem("Edit Markdown") { [weak view] in
            view?.focusSource(in: range)
            view?.window?.makeFirstResponder(view)
        }
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

extension DocumentWindowController: TaskPanelDelegate {
    func taskPanel(_ panel: TaskPanelView, didToggleTaskAt markOffset: Int) {
        markdownDocument.ensureParsedCurrent()
        primaryContainer.textView.preserveViewportOnNextDocumentUpdate()
        splitContainer?.textView.preserveViewportOnNextDocumentUpdate()
        markdownDocument.toggleTask(atMarkOffset: markOffset)
    }

    func taskPanel(_ panel: TaskPanelView, didSelectTaskAt contentOffset: Int) {
        jump(to: contentOffset, label: "Task")
    }

    func taskPanel(_ panel: TaskPanelView, didRequestNewTask text: String, headingIndex: Int?) {
        markdownDocument.ensureParsedCurrent()
        let edits = Restructure.insertTask(markdownDocument.parsed, text: text, headingIndex: headingIndex)
        commitTaskEdits(edits, actionName: "Add Task")
    }

    func taskPanel(_ panel: TaskPanelView, didMoveTask taskIndex: Int, before targetIndex: Int?) {
        markdownDocument.ensureParsedCurrent()
        let edits = Restructure.moveTask(markdownDocument.parsed, taskIndex: taskIndex, before: targetIndex)
        commitTaskEdits(edits, actionName: "Move Task")
    }

    /// Task edits behave like checkbox toggles (§7.1): the document writes
    /// through immediately, the viewport does not jump, and the parse — which
    /// repopulates the panel — lands in the same turn.
    private func commitTaskEdits(_ edits: [TextEdit], actionName: String) {
        guard !edits.isEmpty else { return }
        primaryContainer.textView.preserveViewportOnNextDocumentUpdate()
        splitContainer?.textView.preserveViewportOnNextDocumentUpdate()
        markdownDocument.apply(edits, actionName: actionName)
        markdownDocument.reparseNow()
        if markdownDocument.url != nil { _ = markdownDocument.saveIfNeeded() }
    }
}

extension DocumentWindowController: DensityGutterDelegate {
    func densityGutter(_ gutter: DensityGutterView, didRequestScrollToFraction fraction: CGFloat) {
        let offset = Int(fraction * CGFloat(markdownDocument.parsed.length))
        containerTextView.scroll(
            toOffset: offset,
            position: .top,
            animated: !gutter.isScrubbing
        )
        updateBreadcrumbAndGutter()
    }

    func densityGutter(
        _ gutter: DensityGutterView, previewAtFraction fraction: CGFloat
    ) -> (title: String, snippet: String, context: String)? {
        let offset = Int(fraction * CGFloat(markdownDocument.parsed.length))
        guard let index = markdownDocument.parsed.headings.lastIndex(where: { $0.range.location <= offset }) else {
            return ("Document start", "", densityGutterView.metricsSummary)
        }
        let heading = markdownDocument.parsed.headings[index]
        let sectionPosition = "Section \(index + 1) of \(markdownDocument.parsed.headings.count)"
        let context = heading.wordCount > 0
            ? "\(sectionPosition) · \(heading.wordCount) words"
            : sectionPosition
        if containerTextView.mode == .source || containerTextView.sourceFocus == .document {
            let snippetLength = min(160, max(0, markdownDocument.parsed.length - offset))
            return (
                heading.title,
                markdownDocument.parsed.substring(NSRange(location: offset, length: snippetLength)),
                context
            )
        }
        return (
            heading.title,
            StructuralZoom.sectionPreview(markdownDocument.parsed, headingIndex: index) ?? "Section overview",
            context
        )
    }
}

extension DocumentWindowController: BreadcrumbDelegate {
    func breadcrumb(_ view: BreadcrumbView, didSelectHeadingAt index: Int) {
        guard index < markdownDocument.parsed.headings.count else { return }
        jump(to: markdownDocument.parsed.headings[index].range.location, label: markdownDocument.parsed.headings[index].title)
    }

}

extension DocumentWindowController: FindBarDelegate {
    func findBar(_ bar: FindBarView, didChange query: FindQuery) { scheduleFindQuery(query) }

    func findBar(_ bar: FindBarView, didRequestAdvance forward: Bool) { advanceFind(forward: forward) }

    func findBar(_ bar: FindBarView, didRequestReplace replacement: String, all: Bool) {
        if all {
            let edits = FindEngine.replaceAllEdits(in: markdownDocument.text, query: currentFindQuery, template: replacement)
            markdownDocument.apply(edits, actionName: "Replace All")
            runFind(currentFindQuery)
            replaceResults("Replaced \(edits.count)")
        } else if let match = findSession.currentMatch {
            let text = FindEngine.replacement(
                for: match, in: markdownDocument.text, query: currentFindQuery, template: replacement
            )
            markdownDocument.replace(match, with: text, actionName: "Replace")
            runFind(currentFindQuery)
            replaceResults("Replaced 1")
        } else {
            // Nothing to replace (empty bar). Surface that rather than silently
            // doing nothing when the pill is in replace mode.
            replaceResults("Nothing to replace")
        }
    }

    func findBarDidRequestClose(_ bar: FindBarView) { dismissFindBar() }

    /// A short-lived row confirmation after a replace, so the reader sees the
    /// result instead of a stale "N of M" count.
    private func replaceResults(_ message: String) {
        findBar?.statusText = message
    }
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
        if case .success = markdownDocument.resolveConflictKeepingMine() {
            dismissConflictBar()
        }
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

    /// Arriving is not reviewing — the same rule `jumpChange` follows.  The mark
    /// stays unvisited so its highlight is still there when the reader lands on
    /// it; dwell and departure are what clear it.
    func changeSummaryBar(_ bar: ChangeSummaryBarView, didSelectChangeWith id: UUID) {
        guard let mark = markdownDocument.changes.marks.first(where: { $0.id == id }) else { return }
        jump(to: mark.range.location, label: "Change")
    }

    func changeSummaryBarDidRequestMarkReviewed(_ bar: ChangeSummaryBarView) {
        markdownDocument.changes.clear()
        dismissChangeSummary()
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

extension DocumentWindowController: HistoryInspectorViewDelegate {
    func historyInspectorDidRequestFullHistory(_ inspector: HistoryInspectorView) {
        perform(.versionTimeline)
    }

    func historyInspector(
        _ inspector: HistoryInspectorView,
        didRequestRestore record: SnapshotStore.VersionRecord
    ) {
        let alert = NSAlert()
        alert.messageText = "Restore this version?"
        alert.informativeText = "The current text will be replaced with the selected version. This is an ordinary edit, so ⌘Z undoes it."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        markdownDocument.restore(version: record)
        inspector.versions = markdownDocument.versions()
    }
}
