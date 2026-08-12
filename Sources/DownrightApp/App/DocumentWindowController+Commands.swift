import AppKit
import MarkdownCore
import MarkdownRender

/// Command dispatch.  One switch over the `Command` table (§7.2) — the menu,
/// the keyboard layer, and the toolbar all arrive here, so a command behaves
/// identically however it was invoked.
extension DocumentWindowController: NSMenuItemValidation {
    /// Menu state comes from the command table's preconditions, never from a
    /// second switch that can drift out of step with it.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let command = MainMenu.command(for: menuItem) {
            menuItem.state = commandState(command) ? .on : .off
        }
        return MainMenu.validate(menuItem, in: commandContext)
    }
}

extension DocumentWindowController: CommandResponder {
    @objc func performDownrightCommand(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let command = MainMenu.command(for: item) else { return }
        perform(command)
    }

    /// The facts this window contributes to command validation.
    var commandContext: CommandContext {
        CommandContext(
            hasDocument: true,
            documentHasFile: markdownDocument.url != nil,
            hasSelection: containerTextView.sourceSelectedRange.length > 0,
            canCheckForUpdates: UpdateCoordinator.shared.canCheckForUpdates,
            hasUnsavedChanges: markdownDocument.isDirty,
            hasFindQuery: !findSession.query.isEmpty,
            canGoBack: jumpHistory.canGoBack,
            canGoForward: jumpHistory.canGoForward,
            isSpeaking: isSpeakingDocument,
            caretIsInTable: caretIsInTable,
            hasChangeMarks: !markdownDocument.changes.decoratedMarks.isEmpty
        )
    }

    /// Wires the text view's `keyDown` into the binding store — the one layer
    /// that previously had zero call sites, leaving the bare 1–5 zoom keys,
    /// the read-mode `space`/`n`/`p` keys, `⌥↓`/`⌥↑` change jumps, and the vim
    /// layer unreachable.  The scope mirrors the surface's real state: an
    /// editable surface has a caret, so bare single-letter read bindings defer
    /// to typing there and only modified chords run; a read-only surface uses
    /// `.read`, where those bare keys are exactly what §7.2 spends them on.
    @MainActor
    func wireKeyEventHandler(_ textView: MarkdownTextView) {
        textView.keyEventHandler = { [weak self] event in
            guard let self else { return false }
            return self.dispatchKeyEvent(event, in: textView)
        }
    }

    private func dispatchKeyEvent(_ event: NSEvent, in textView: MarkdownTextView) -> Bool {
        let scope: CommandScope
        if textView.sourceFocus != .none {
            scope = .source
        } else if !textView.isEditable {
            scope = .read
        } else {
            scope = .live
        }
        guard let command = KeybindingStore.shared.command(for: event, scope: scope) else { return false }

        // An editable surface has a caret, so an unmodified key is input, not a
        // command (§7.2's whole premise).  Without this guard the read-layer
        // extras that share the default scope — notably the `[`/`]` change
        // navigation — would swallow literal typing.  Read mode has no caret,
        // so bare keys (space, 1–5, n, p, j/k/g/G, `[`/`]`) fire there.
        //
        // Tab is the exception: it is bound to Indent/Outdent in `.live`, and
        // those are the keys every editor uses for list nesting.  It stays
        // safe because `indentSelection` reports failure when the caret is not
        // in a list item, and the text view then inserts the literal tab.
        if scope != .read,
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           KeyBinding.key(for: event) != "tab" {
            return false
        }

        switch command {
        case .scrollDown:
            textView.scrollLineDown(nil)
            return true
        case .scrollUp:
            textView.scrollLineUp(nil)
            return true
        case .pageDown:
            textView.scrollPageDown(nil)
            return true
        case .pageUp:
            textView.scrollPageUp(nil)
            return true
        default:
            return perform(command)
        }
    }

    @discardableResult
    func perform(_ command: Command) -> Bool {
        switch command {

        // MARK: Modes
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
        case .statusBar:
            Preferences.shared.update { $0.showStatusBar.toggle() }

        // MARK: Panels
        case .taskPanel: toggleTaskPanel()
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
        case .markChangesReviewed: markChangesReviewed()
        case .followLinkAtCaret: return textView.activateLinkAtCaret()
        case .nextLink: return textView.moveToLink(forward: true)
        case .previousLink: return textView.moveToLink(forward: false)
        case .documentStart: jump(to: 0, label: "Top")
        case .documentEnd: jump(to: markdownDocument.parsed.length, label: "End")
        case .goBack: goBack()
        case .goForward: goForward()
        case .goToLine: goToLine()
        // Scrolling is geometry the text view owns, but the Navigate menu items
        // arrive here, so route them rather than dropping them on the floor.
        case .scrollDown: textView.scrollLineDown(nil)
        case .scrollUp: textView.scrollLineUp(nil)
        case .pageDown: textView.scrollPageDown(nil)
        case .pageUp: textView.scrollPageUp(nil)

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
        case .headingLevel1: setHeadingLevel(1)
        case .headingLevel2: setHeadingLevel(2)
        case .headingLevel3: setHeadingLevel(3)
        case .headingLevel4: setHeadingLevel(4)
        case .headingLevel5: setHeadingLevel(5)
        case .headingLevel6: setHeadingLevel(6)
        case .headingToBody: convertHeadingToBody()
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
        // Report whether the caret was actually in a list item, so Tab can
        // fall through to a literal tab when it was not.
        case .indentList: return indentSelection(outdent: false)
        case .outdentList: return indentSelection(outdent: true)
        case .toggleTaskAtCaret: toggleTaskAtCaret()

        // MARK: Files
        case .save: _ = saveDocument()
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
             .compareFiles, .checkForUpdates, .toggleLightDark:
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
        setSharedZoom(level)
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
        // Arriving is not reviewing.  Marking visited here fired `onChange`,
        // which rebuilt the decorations without this mark — so the highlight
        // vanished at the exact moment the reader landed on it.  Departure and
        // dwell are handled by `noteVisibleChangeMarks`.
        jump(to: mark.range.location, label: "Change")
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
        guard !edits.isEmpty else { return }
        let viewportRepairs = documentPanes.map { $0.textView.makeViewportRepair() }
        markdownDocument.apply(edits, actionName: promote ? "Promote Heading" : "Demote Heading")
        viewportRepairs.forEach { $0() }
    }

    private func setHeadingLevel(_ level: Int) {
        markdownDocument.ensureParsedCurrent()
        guard let index = currentHeadingIndex() else { return }
        let edits = Restructure.setHeadingLevel(markdownDocument.parsed, headingIndex: index, level: level)
        guard !edits.isEmpty else { return }
        let viewportRepairs = documentPanes.map { $0.textView.makeViewportRepair() }
        markdownDocument.apply(edits, actionName: "Set Heading (level)")
        viewportRepairs.forEach { $0() }
    }

    private func convertHeadingToBody() {
        markdownDocument.ensureParsedCurrent()
        guard let index = currentHeadingIndex() else { return }
        let edits = Restructure.headingToBodyText(markdownDocument.parsed, headingIndex: index)
        guard !edits.isEmpty else { return }
        let viewportRepairs = documentPanes.map { $0.textView.makeViewportRepair() }
        markdownDocument.apply(edits, actionName: "Body Text")
        viewportRepairs.forEach { $0() }
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
        var folds = textView.foldedHeadingSlugs
        if fold { folds.insert(slug) } else { folds.remove(slug) }
        setSharedFolds(folds, from: textView)
    }

    private func setAllFolds(folded: Bool) {
        markdownDocument.ensureParsedCurrent()
        setSharedFolds(folded ? Set(markdownDocument.parsed.headings.map(\.slug)) : [], from: textView)
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
        // Deliberately NOT `selectionRange()`.  That helper widens an empty
        // selection to the caret's whole block, which is right for ⌘B and the
        // convert commands and very wrong here: ⌘K with nothing selected
        // swallowed the entire paragraph into `[…]()`.
        let range = containerTextView.sourceSelectedRange
        let selected = range.length > 0
            ? (markdownDocument.text as NSString).substring(with: range)
            : ""
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        // A URL already on the clipboard is the common case and turns ⌘K into
        // a one-keystroke operation (§6.4 smart paste, applied to ⌘K).
        let destination = clipboard.hasPrefix("http") ? clipboard : ""
        let replacement = "[\(selected)](\(destination))"
        markdownDocument.replace(range, with: replacement, actionName: "Insert Link")
        // Land the caret on whichever half the user still has to fill in.
        let end = range.location + replacement.utf16.count
        let caret: Int
        if selected.isEmpty {
            caret = range.location + 1              // inside the empty [ ]
        } else if destination.isEmpty {
            caret = end - 1                         // inside the empty ( )
        } else {
            caret = end                             // both filled: carry on typing
        }
        textView.setSelectedRange(NSRange(location: caret, length: 0))
    }

    /// Returns false when the caret's line is not a list item, which is what
    /// lets Tab reach the text view and type a literal tab instead.
    @discardableResult
    private func indentSelection(outdent: Bool) -> Bool {
        markdownDocument.ensureParsedCurrent()
        let line = (markdownDocument.text as NSString).lineRange(for: selectionRange())
        let edits = ListEditing.indent(markdownDocument.parsed, lineRange: line, outdent: outdent)
        guard !edits.isEmpty else { return false }
        markdownDocument.apply(edits, actionName: outdent ? "Outdent" : "Indent")
        return true
    }

    private func toggleTaskAtCaret() {
        markdownDocument.ensureParsedCurrent()
        let offset = caretOffset()
        guard let task = markdownDocument.parsed.tasks.first(where: {
            $0.contentRange.touches(offset: offset) || $0.markRange.touches(offset: offset)
        }) else { return }
        markdownDocument.toggleTask(atMarkOffset: task.markRange.location)
    }

    /// Shows a small dialog to jump to a line number.  The line number is
    /// one-based, matching what a reader sees in a text editor status bar.
    private func goToLine() {
        let text = markdownDocument.text as NSString
        let totalLines = max(1, text.length == 0 ? 1 :
            (text.substring(from: max(0, text.length - 1)) == "\n"
                ? text.components(separatedBy: "\n").count - 1
                : text.components(separatedBy: "\n").count))
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Enter a line number (1–\(totalLines)):"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.placeholderString = "Line number"
        input.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        alert.accessoryView = input
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let lineNumber = Int(input.stringValue.trimmingCharacters(in: .whitespaces)),
              lineNumber > 0 else { return }
        let targetLine = min(lineNumber - 1, totalLines - 1)
        let lines = text.components(separatedBy: "\n")
        var offset = 0
        for i in 0..<min(targetLine, lines.count) {
            offset += lines[i].utf16.count + 1  // +1 for the newline
        }
        offset = min(offset, text.length)
        jump(to: offset, label: "Line \(lineNumber)")
    }

    private func useSelectionForFind() {
        let range = containerTextView.sourceSelectedRange
        guard range.length > 0 else { return }
        var query = FindQuery()
        query.text = (markdownDocument.text as NSString).substring(with: range)
        showFindBar(replace: false, queryAfterFocus: query)
    }

    // MARK: - Text size

    func adjustTextSize(by delta: CGFloat) {
        Preferences.shared.update {
            $0.textSizeAdjustment = max(-4, min(10, $0.textSizeAdjustment + delta))
        }
    }
}
