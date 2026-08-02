import AppKit
import MarkdownCore
import MarkdownRender

/// Command dispatch.  One switch over the `Command` table (§7.2) — the menu,
/// the keyboard layer, and the toolbar all arrive here, so a command behaves
/// identically however it was invoked.
extension DocumentWindowController: CommandResponder {
    @objc func performDownrightCommand(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let command = MainMenu.command(for: item) else { return }
        perform(command)
    }

    @discardableResult
    func perform(_ command: Command) -> Bool {
        switch command {

        // MARK: Modes
        case .toggleReadLive:
            containerTextView.clearSourceFocus()
        case .sourceMode:
            if containerTextView.sourceFocus == .none {
                containerTextView.focusEntireSource()
            } else {
                containerTextView.clearSourceFocus()
            }
        case .splitView:
            toggleSplitView()
        case .pinWindow:
            togglePin()
        case .focusMode:
            toggleFocusMode()
        case .typewriterScrolling:
            Preferences.shared.update { $0.typewriterScrolling.toggle() }

        // MARK: Panels
        case .outlinePanel: toggleOutlinePanel()
        case .taskPanel: toggleTaskPanel()
        case .toggleSidebar: toggleSiblingSidebar()
        case .outlineQuickOpen: showOutlineQuickOpen()
        case .versionTimeline: showVersionTimeline()
        case .frontMatterEditor: showFrontMatterEditor()
        case .tableEditor: presentTableEditor()
        case .assetDoctor: toggleAssetDoctorPanel()
        case .commandPalette: showCommandPalette()
        case .documentLens: toggleDocumentLensPanel()
        case .readerProfiles: showReaderProfiles()
        case .documentHealth: toggleDocumentHealthPanel()
        case .renderTargets: toggleRenderTargetsPanel()
        case .visualDebugger: toggleVisualDebuggerPanel()
        case .reviewPanel: showReviewPanel()
        case .workspace: toggleWorkspaceSidebar()
        case .localAI: showLocalAIPanel()

        // MARK: Navigation
        case .nextHeading: jumpHeading(forward: true)
        case .previousHeading: jumpHeading(forward: false)
        case .nextChange: jumpChange(forward: true)
        case .previousChange: jumpChange(forward: false)
        case .documentStart: jump(to: 0, label: "Top")
        case .documentEnd: jump(to: markdownDocument.parsed.length, label: "End")
        case .goBack: goBack()
        case .goForward: goForward()
        case .scrollDown, .scrollUp, .pageDown, .pageUp, .cycleFocusable, .activateFocused:
            // Handled by the text view's own key handling, where the scroll
            // geometry lives.
            return false

        // MARK: Structural zoom (§5.2)
        case .zoomLevel1: setZoom(.h1)
        case .zoomLevel2: setZoom(.h2)
        case .zoomLevel3: setZoom(.headings)
        case .zoomLevel4: setZoom(.skeleton)
        case .zoomLevel5: setZoom(.everything)
        case .zoomIn: setZoom(ZoomLevel(rawValue: min(5, textView.zoomLevel.rawValue + 1)) ?? .everything)
        case .zoomOut: setZoom(ZoomLevel(rawValue: max(1, textView.zoomLevel.rawValue - 1)) ?? .h1)

        // MARK: Find (§9.4)
        case .find: showFindBar(replace: false)
        case .findReplace: showFindBar(replace: true)
        case .findNext: advanceFind(forward: true)
        case .findPrevious: advanceFind(forward: false)
        case .findInSiblings: showSiblingSearch()
        case .useSelectionForFind: useSelectionForFind()

        // MARK: Restructuring (§9.2)
        case .promoteHeading: restructureHeading(promote: true)
        case .demoteHeading: restructureHeading(promote: false)
        case .moveBlockUp: moveBlock(.up)
        case .moveBlockDown: moveBlock(.down)
        case .foldSection: foldCurrentSection(fold: true)
        case .unfoldSection: foldCurrentSection(fold: false)
        case .foldAll: setAllFolds(folded: true)
        case .unfoldAll: setAllFolds(folded: false)
        case .convertToParagraph: convertSelection(to: .paragraph)
        case .convertToBulletList: convertSelection(to: .bulletList)
        case .convertToNumberedList: convertSelection(to: .numberedList)
        case .convertToTaskList: convertSelection(to: .taskList)
        case .convertToBlockquote: convertSelection(to: .blockquote)
        case .sortListAlphabetically: sortList(order: .alphabetical)
        case .sortListByState: sortList(order: .uncheckedFirst)
        case .insertTableOfContents: insertTableOfContents()
        case .tidyDocument: showTidySheet()

        // MARK: Editing (§6.4)
        case .toggleBold: wrapSelection(with: "**", name: "Bold")
        case .toggleItalic: wrapSelection(with: "_", name: "Italic")
        case .toggleStrikethrough: wrapSelection(with: "~~", name: "Strikethrough")
        case .toggleInlineCode: wrapSelection(with: "`", name: "Inline Code")
        case .insertLink: insertLink()
        case .indentList: indentSelection(outdent: false)
        case .outdentList: indentSelection(outdent: true)
        case .toggleTaskAtCaret: toggleTaskAtCaret()
        case .addCursorAbove, .addCursorBelow, .selectNextOccurrence, .splitSelectionIntoLines:
            return false  // multiple cursors live in the text view

        // MARK: Files
        case .save: try? markdownDocument.save()
        case .saveAs: saveAs()
        case .close: window?.performClose(nil)
        case .revealInFinder:
            guard let url = markdownDocument.url else { return true }
            authorizeLocalEffect(.launchPathOrEditor, target: url) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .openInEditor:
            guard let url = markdownDocument.url else { return true }
            authorizeLocalEffect(.launchPathOrEditor, target: url) {
                Preferences.shared.values.externalEditor.open(url, line: nil)
            }

        // MARK: Copy and export (§9.5)
        case .copyAsMarkdown: copy(flavour: .markdown)
        case .copyAsRichText: copy(flavour: .richText)
        case .copyAsPlainText: copy(flavour: .plain)
        case .copySection: copyCurrentSection()
        case .copySectionLink: copySectionLink()
        case .printDocument: printDocument()
        case .exportHTML: exportHTML()
        case .exportPDF: exportPDF()
        case .exportSelectionAsImage: exportSelectionAsImage()
        case .increaseTextSize: adjustTextSize(by: 1)
        case .decreaseTextSize: adjustTextSize(by: -1)
        case .resetTextSize: Preferences.shared.update { $0.textSizeAdjustment = 0 }
        case .speakDocument: speakSelectionOrDocument()
        case .stopSpeaking: stopSpeaking()

        // MARK: Application-level
        case .newDocument, .open, .preferences, .showKeybindings, .reloadTheme,
             .toggleVimKeys, .compareFiles:
            return (NSApp.delegate as? AppDelegate)?.handleApplicationCommand(command) ?? false
        }
        return true
    }

    private var textView: MarkdownTextView { containerTextView }

    // MARK: - Zoom

    private func setZoom(_ level: ZoomLevel) {
        // Headings hold their vertical position through the transition, so the
        // reader never loses their place (§5.2) — the text view anchors on the
        // nearest heading before relayout.
        textView.zoomLevel = level
        markdownDocument.state.zoomLevel = level
        outlinePanel?.zoomLevel = level
    }

    // MARK: - Navigation helpers

    private func jumpHeading(forward: Bool) {
        let offset = textView.topVisibleOffset
        let headings = markdownDocument.parsed.headings
        let target = forward
            ? headings.first { $0.range.location > offset + 1 }
            : headings.last { $0.range.location < offset - 1 }
        guard let target else { return }
        jump(to: target.range.location, label: target.title)
    }

    private func jumpChange(forward: Bool) {
        let offset = textView.topVisibleOffset
        let mark = forward
            ? markdownDocument.changes.next(after: offset)
            : markdownDocument.changes.previous(before: offset)
        guard let mark else { return }
        markdownDocument.changes.markVisited(mark.id)
        jump(to: mark.range.location, label: "Change")
    }

    private func showOutlineQuickOpen() {
        openNavigationOverlay(focusSearch: true)
    }

    private func showVersionTimeline() {
        guard markdownDocument.url != nil else { return }
        let controller = VersionTimelineWindowController(document: markdownDocument, styleSheet: currentStyleSheet)
        controller.showWindow(nil)
        retainTimeline(controller)
    }

    // MARK: - Restructuring

    private func restructureHeading(promote: Bool) {
        markdownDocument.ensureParsedCurrent()
        guard let index = currentHeadingIndex() else { return }
        let edits = promote
            ? Restructure.promoteHeading(markdownDocument.parsed, headingIndex: index)
            : Restructure.demoteHeading(markdownDocument.parsed, headingIndex: index)
        markdownDocument.apply(edits, actionName: promote ? "Promote Heading" : "Demote Heading")
    }

    private func moveBlock(_ direction: MoveDirection) {
        markdownDocument.ensureParsedCurrent()
        let offset = caretOffset()
        let edits = Restructure.moveBlock(markdownDocument.parsed, containing: offset, direction)
        markdownDocument.apply(edits, actionName: direction == .up ? "Move Block Up" : "Move Block Down")
    }

    private func convertSelection(to conversion: ListConversion) {
        markdownDocument.ensureParsedCurrent()
        let edits = Restructure.convert(markdownDocument.parsed, range: selectionRange(), to: conversion)
        markdownDocument.apply(edits, actionName: "Convert to \(conversion.title)")
    }

    private func sortList(order: ListSortOrder) {
        markdownDocument.ensureParsedCurrent()
        let edits = Restructure.sortList(markdownDocument.parsed, containing: caretOffset(), order: order)
        markdownDocument.apply(edits, actionName: "Sort List")
    }

    private func insertTableOfContents() {
        markdownDocument.ensureParsedCurrent()
        let toc = Restructure.tableOfContents(markdownDocument.parsed, maxLevel: 3)
        guard !toc.isEmpty else { return }
        let insertion = markdownDocument.parsed.frontMatter.map { $0.range.upperBound } ?? 0
        markdownDocument.apply(
            [TextEdit(range: NSRange(location: insertion, length: 0), replacement: toc, summary: "Table of contents")],
            actionName: "Insert Table of Contents"
        )
    }

    private func foldCurrentSection(fold: Bool) {
        markdownDocument.ensureParsedCurrent()
        guard let index = currentHeadingIndex() else { return }
        let slug = markdownDocument.parsed.headings[index].slug
        if fold { textView.foldedHeadingSlugs.insert(slug) } else { textView.foldedHeadingSlugs.remove(slug) }
        markdownDocument.state.foldedHeadings = textView.foldedHeadingSlugs
    }

    private func setAllFolds(folded: Bool) {
        markdownDocument.ensureParsedCurrent()
        textView.foldedHeadingSlugs = folded ? Set(markdownDocument.parsed.headings.map(\.slug)) : []
        markdownDocument.state.foldedHeadings = textView.foldedHeadingSlugs
    }

    private func showTidySheet() {
        markdownDocument.ensureParsedCurrent()
        let edits = TidyDocument.plan(markdownDocument.parsed)
        guard !edits.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Nothing to tidy"
            alert.informativeText = "This markdownDocument already follows every rule Tidy checks."
            alert.runModal()
            return
        }
        presentTidySheet(edits)
    }

    // MARK: - Editing helpers

    private func wrapSelection(with marker: String, name: String) {
        let range = selectionRange()
        let text = markdownDocument.text as NSString
        guard range.length > 0 else {
            let insertion = "\(marker)\(marker)"
            markdownDocument.replace(NSRange(location: range.location, length: 0), with: insertion, actionName: name)
            textView.setSelectedRange(NSRange(location: range.location + marker.count, length: 0))
            return
        }
        let selected = text.substring(with: range)
        // Toggling off is the same operation read backwards, which keeps ⌘B on
        // already-bold text doing what everybody expects.
        if selected.hasPrefix(marker), selected.hasSuffix(marker), selected.count > marker.count * 2 {
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            markdownDocument.replace(range, with: inner, actionName: name)
        } else {
            markdownDocument.replace(range, with: marker + selected + marker, actionName: name)
        }
    }

    private func insertLink() {
        let range = selectionRange()
        let selected = (markdownDocument.text as NSString).substring(with: range)
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        // A URL already on the clipboard is the common case and turns ⌘K into
        // a one-keystroke operation (§6.4 smart paste, applied to ⌘K).
        let destination = clipboard.hasPrefix("http") ? clipboard : ""
        let replacement = "[\(selected)](\(destination))"
        markdownDocument.replace(range, with: replacement, actionName: "Insert Link")
        let caret = range.location + replacement.utf16.count - 1
        textView.setSelectedRange(NSRange(location: destination.isEmpty ? caret : caret + 1, length: 0))
    }

    private func indentSelection(outdent: Bool) {
        markdownDocument.ensureParsedCurrent()
        let line = (markdownDocument.text as NSString).lineRange(for: selectionRange())
        let edits = ListEditing.indent(markdownDocument.parsed, lineRange: line, outdent: outdent)
        markdownDocument.apply(edits, actionName: outdent ? "Outdent" : "Indent")
    }

    private func toggleTaskAtCaret() {
        markdownDocument.ensureParsedCurrent()
        let offset = caretOffset()
        guard let task = markdownDocument.parsed.tasks.first(where: {
            $0.contentRange.touches(offset: offset) || $0.markRange.touches(offset: offset)
        }) else { return }
        markdownDocument.toggleTask(atMarkOffset: task.markRange.location)
    }

    private func useSelectionForFind() {
        let range = selectionRange()
        guard range.length > 0 else { return }
        var query = FindQuery()
        query.text = (markdownDocument.text as NSString).substring(with: range)
        showFindBar(replace: false)
        applyFindQuery(query)
    }

    // MARK: - Text size

    private func adjustTextSize(by delta: CGFloat) {
        Preferences.shared.update {
            $0.textSizeAdjustment = max(-4, min(10, $0.textSizeAdjustment + delta))
        }
    }
}
