import AppKit
import MarkdownCore

// §7.1 — the pointer is the primary interaction path, and every capability
// here is reachable without touching the keyboard.  Read mode has no insertion
// caret and *all* of this still works.
extension MarkdownTextView {

    // MARK: - Hit testing

    /// Source offset for a point in view coordinates.
    ///
    /// `characterIndexForInsertion` speaks TextKit's hybrid space, so this is
    /// one of the boundaries where a conversion is mandatory.
    public func sourceOffset(at point: NSPoint) -> Int {
        currentDisplayMap.sourceOffset(forTextKit: characterIndexForInsertion(at: point))
    }

    /// Attribute under the pointer.  Checks the character before the insertion
    /// index as well, because an insertion index sits *between* characters and
    /// a link's last glyph would otherwise not be hoverable.
    func attribute(_ key: NSAttributedString.Key, at point: NSPoint) -> (value: Any, range: NSRange)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let offset = sourceOffset(at: point)
        for candidate in [offset, offset - 1] where candidate >= 0 && candidate < storage.length {
            var range = NSRange(location: 0, length: 0)
            if let value = storage.attribute(key, at: candidate, effectiveRange: &range) {
                return (value, range)
            }
        }
        return nil
    }

    func fragmentPayload(at point: NSPoint) -> (payload: FragmentPayload, range: NSRange)? {
        guard let hit = attribute(.drFragment, at: point), let payload = hit.value as? FragmentPayload else { return nil }
        return (payload, hit.range)
    }

    // MARK: - Hover (§7.1)

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHover()
    }

    private func updateHover(at point: NSPoint) {
        var needsRedraw = false
        let payload = fragmentPayload(at: point)?.payload

        // Code blocks reveal a copy button; tables zebra the row under the
        // pointer (§7.1, §11.3).
        let codeRange = (payload?.kind == .codeBlock || payload?.kind == .collapsedCodeBlock)
            ? payload?.sourceRange : nil
        if fragmentContext.hoveredFragmentRange != codeRange {
            fragmentContext.hoveredFragmentRange = codeRange
            needsRedraw = true
        }

        var rowRange: NSRange?
        if payload?.kind == .table, let table = payload?.tableData {
            let offset = sourceOffset(at: point)
            rowRange = table.rows.first { !$0.isHeader && $0.range.contains(offset: offset) }?.range
        }
        if fragmentContext.hoveredTableRow != rowRange {
            fragmentContext.hoveredTableRow = rowRange
            needsRedraw = true
        }

        // Hovering a heading puts an anchor glyph in the gutter (§7.1).
        let offset = sourceOffset(at: point)
        let headingIndex = parsedDocument.headings.firstIndex { $0.range.contains(offset: offset) }
        if hoveredHeadingIndex != headingIndex {
            hoveredHeadingIndex = headingIndex
            gutterRail?.needsDisplay = true
        }

        if attribute(.drLink, at: point) != nil || attribute(.drReference, at: point) != nil
            || attribute(.drPathToken, at: point) != nil
            || attribute(.drCheckbox, at: point) != nil {
            NSCursor.pointingHand.set()
        }

        let nextToolTip: String?
        if payload?.kind != .image,
           let hit = attribute(.drReference, at: point),
           let identifier = hit.value as? String,
           let footnote = parsedDocument.footnotes[identifier] {
            nextToolTip = parsedDocument.substring(footnote.contentRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let hit = attribute(.drLink, at: point), let destination = hit.value as? String {
            nextToolTip = destination
        } else {
            nextToolTip = nil
        }
        if toolTip != nextToolTip { toolTip = nextToolTip }

        if needsRedraw { needsDisplay = true }
    }

    private func clearHover() {
        fragmentContext.hoveredFragmentRange = nil
        fragmentContext.hoveredTableRow = nil
        hoveredHeadingIndex = nil
        toolTip = nil
        needsDisplay = true
        gutterRail?.needsDisplay = true
    }

    public override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if attribute(.drLink, at: point) != nil || attribute(.drReference, at: point) != nil
            || attribute(.drPathToken, at: point) != nil
            || attribute(.drCheckbox, at: point) != nil {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    // MARK: - Click (§7.1)

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if sourceFocusDoneRect?.insetBy(dx: -4, dy: -4).contains(point) == true {
            clearSourceFocus()
            return
        }

        if handleCodeBlockChrome(at: point) { return }

        // Clicking a checkbox toggles it and the file is written immediately —
        // §7.1 and §8.5.  Works in every mode, including Read.
        if let hit = attribute(.drCheckbox, at: point) {
            markdownDelegate?.markdownTextView(self, didToggleCheckboxAtMarkOffset: hit.range.location)
            return
        }

        // In Live and Source a plain click places the caret; ⌘ activates.
        // In Read there is no caret, so a plain click activates (§3.2, §5).
        let activates = (mode == .read) || modifiers.contains(.command)

        if activates, let hit = attribute(.drPathToken, at: point), let token = hit.value as? PathToken {
            markdownDelegate?.markdownTextView(self, didActivatePathToken: token, at: hit.range)
            return
        }
        if activates, let hit = attribute(.drLink, at: point), let destination = hit.value as? String {
            markdownDelegate?.markdownTextView(self, didActivateLink: destination, at: hit.range, modifiers: modifiers)
            return
        }
        if activates,
           let hit = attribute(.drReference, at: point),
           let identifier = hit.value as? String,
           let footnote = parsedDocument.footnotes[identifier] {
            scroll(toOffset: footnote.range.location, position: .center, animated: true)
            return
        }
        if activates, let payload = fragmentPayload(at: point)?.payload, payload.kind == .image {
            // §7.1: click an image → lightbox.  The render package owns no
            // windows, so it reports and the app presents.
            markdownDelegate?.markdownTextView(
                self,
                didActivateImage: payload.detail,
                at: payload.sourceRange
            )
            return
        }

        // `super` owns the whole click/drag gesture.  Delay marker reveal until
        // it resolves to a caret or a selection, so selection never causes a
        // transient source flash or moves the glyphs under the pointer.
        suppressesCaretReveal = true
        super.mouseDown(with: event)
        suppressesCaretReveal = false

        if case .scoped(let focus) = sourceFocus {
            let selection = sourceSelectedRange
            let remainsInside = selection.length == 0
                ? focus.contains(offset: selection.location)
                : NSIntersectionRange(focus, selection).length > 0
            if !remainsInside {
                clearSourceFocus()
                return
            }
        }
        handleSelectionChanged()
    }

    public override func cancelOperation(_ sender: Any?) {
        guard sourceFocus != .none else {
            super.cancelOperation(sender)
            return
        }
        clearSourceFocus()
    }

    /// Copy button and collapsed-chip expansion, both hit-tested against the
    /// same geometry the fragment draws with.
    private func handleCodeBlockChrome(at point: NSPoint) -> Bool {
        guard let hit = fragmentPayload(at: point) else { return false }
        let payload = hit.payload
        guard payload.kind == .codeBlock || payload.kind == .collapsedCodeBlock else { return false }

        let collapsed = isCollapsed(payload)
        guard let chrome = rect(forOffset: payload.sourceRange.location) else { return false }

        if collapsed {
            // §5.1: click the chip to expand.
            setCodeBlockCollapsed(false, at: payload.sourceRange.location)
            return true
        }

        let indent = max(
            0,
            ((textStorage?.attribute(.paragraphStyle, at: payload.sourceRange.location, effectiveRange: nil)
                as? NSParagraphStyle)?.headIndent ?? RenderMetrics.codeInsetX) - RenderMetrics.codeInsetX
        )
        let band = CGRect(
            x: indent,
            y: chrome.minY,
            width: max(1, styleSheet.measureWidth - indent),
            height: chrome.height
        )
        let copy = CodeBlockFragment.copyButtonRect(in: band, style: styleSheet, language: payload.detail)
        let local = CGPoint(x: point.x - textContainerOrigin.x, y: point.y)
        guard copy.insetBy(dx: -3, dy: -3).contains(local) else { return false }

        return copyCodeBlock(payload)
    }

    func copyCodeBlockForAccessibility() -> Bool {
        let payload: FragmentPayload?
        if let range = fragmentContext.hoveredFragmentRange,
           let storage = textStorage, range.location >= 0, range.location < storage.length,
           let value = storage.attribute(.drFragment, at: range.location, effectiveRange: nil) {
            payload = value as? FragmentPayload
        } else {
            let selection = sourceSelectedRange
            guard let storage = textStorage, selection.location >= 0, selection.location < storage.length else {
                return false
            }
            payload = storage.attribute(.drFragment, at: selection.location, effectiveRange: nil) as? FragmentPayload
        }
        guard let payload,
              payload.kind == .codeBlock || payload.kind == .collapsedCodeBlock else { return false }
        return copyCodeBlock(payload)
    }

    private func copyCodeBlock(_ payload: FragmentPayload) -> Bool {
        let code = codeText(of: payload)
        guard !code.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        fragmentContext.copiedCodeRange = payload.sourceRange
        copiedCodeFeedbackWorkItem?.cancel()
        needsDisplay = true
        let copiedRange = payload.sourceRange
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.fragmentContext.copiedCodeRange == copiedRange else { return }
            self.fragmentContext.copiedCodeRange = nil
            self.needsDisplay = true
        }
        copiedCodeFeedbackWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
        return true
    }

    private func codeText(of payload: FragmentPayload) -> String {
        guard let storage = textStorage else { return "" }
        var range = payload.sourceRange
        range.location = max(0, range.location)
        range.length = min(range.length, storage.length - range.location)
        guard range.length > 0 else { return "" }
        // Strip the fences: what you want on the pasteboard is the code.
        let lines = storage.attributedSubstring(from: range).string
            .components(separatedBy: "\n")
        var body = lines
        if body.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { body.removeFirst() }
        if body.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { body.removeLast() }
        if body.last?.isEmpty == true { body.removeLast() }
        return body.joined(separator: "\n")
    }

    // MARK: - Context menus (§7.1)

    public override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let offset = sourceOffset(at: point)
        let target = contextTarget(at: point, offset: offset)
        if let menu = markdownDelegate?.markdownTextView(self, wantsContextMenuFor: target) { return menu }
        return super.menu(for: event)
    }

    private func contextTarget(at point: NSPoint, offset: Int) -> ContextTarget {
        if let hit = attribute(.drPathToken, at: point), let token = hit.value as? PathToken {
            return ContextTarget(kind: .pathToken(token), sourceRange: hit.range, hitOffset: offset)
        }
        if let hit = fragmentPayload(at: point) {
            switch hit.payload.kind {
            case .codeBlock, .collapsedCodeBlock:
                return ContextTarget(
                    kind: .codeBlock(hit.payload.sourceRange),
                    sourceRange: hit.payload.sourceRange,
                    hitOffset: offset
                )
            case .table:
                return ContextTarget(
                    kind: .table(hit.payload.sourceRange),
                    sourceRange: hit.payload.sourceRange,
                    hitOffset: offset
                )
            case .image:
                return ContextTarget(
                    kind: .image(hit.payload.detail),
                    sourceRange: hit.payload.sourceRange,
                    hitOffset: offset
                )
            default:
                break
            }
        }
        if let hit = attribute(.drLink, at: point), let destination = hit.value as? String {
            return ContextTarget(kind: .link(destination), sourceRange: hit.range, hitOffset: offset)
        }
        if let index = parsedDocument.headings.firstIndex(where: { $0.range.contains(offset: offset) }) {
            return ContextTarget(
                kind: .heading(index),
                sourceRange: parsedDocument.headings[index].sectionRange,
                hitOffset: offset
            )
        }
        let selection = sourceSelectedRange
        if selection.length > 0, selection.contains(offset: offset) {
            return ContextTarget(kind: .selection, sourceRange: selection, hitOffset: offset)
        }
        return ContextTarget(
            kind: .plain,
            sourceRange: NSRange(location: offset, length: 0),
            hitOffset: offset
        )
    }

    /// Called by the gutter rail when a marker or anchor glyph is clicked.
    func activateHeadingAnchor(_ index: Int, modifiers: NSEvent.ModifierFlags) {
        markdownDelegate?.markdownTextView(self, didActivateHeadingAnchor: index, modifiers: modifiers)
    }

    // MARK: - Editing, in source coordinates

    /// Every mutation in the view funnels through here.  The range is a
    /// *source* range; nothing else is ever handed to the storage, which is
    /// how §3.1's guarantee survives contact with AppKit's editing pipeline.
    @discardableResult
    public func performSourceEdit(range: NSRange, replacement: String) -> Bool {
        guard isEditable, let storage = textStorage else { return false }
        let clamped = NSRange(location: max(0, min(range.location, storage.length)),
                              length: max(0, min(range.length, storage.length - min(range.location, storage.length))))
        guard shouldChangeText(in: clamped, replacementString: replacement) else { return false }
        // Structural zoom is a reading projection. Editing through an elided
        // projection makes nearby paragraphs appear and disappear around the
        // caret, so the first mutation returns to the complete document.
        if zoomLevel != .everything { zoomLevel = .everything }

        let oldParagraphs = paragraphIndex
        let oldHiddenRanges = currentDisplayMap.hiddenRanges
        beginSourceEdit()
        storage.replaceCharacters(in: clamped, with: replacement)
        let inserted = (replacement as NSString).length
        rebuildParagraphIndex()
        adjustScopedSourceFocus(forEdit: clamped, insertedLength: inserted)
        projectDisplayMapAcrossEdit(
            clamped,
            insertedLength: inserted,
            oldParagraphs: oldParagraphs,
            oldHiddenRanges: oldHiddenRanges
        )
        didChangeText()
        endSourceEdit()

        markdownDelegate?.markdownTextView(self, didEdit: clamped, delta: inserted - clamped.length)
        setSourceSelectedRanges([NSRange(location: clamped.location + inserted, length: 0)])
        return true
    }

    private func adjustScopedSourceFocus(forEdit edit: NSRange, insertedLength: Int) {
        guard case .scoped(let focus) = sourceFocus else { return }
        let delta = insertedLength - edit.length
        let start: Int
        if edit.upperBound <= focus.location {
            start = focus.location + delta
        } else if edit.location < focus.location {
            start = edit.location
        } else {
            start = focus.location
        }

        let end: Int
        if edit.location >= focus.upperBound {
            end = focus.upperBound
        } else if edit.upperBound <= focus.upperBound {
            end = focus.upperBound + delta
        } else {
            end = edit.location + insertedLength
        }

        let storageLength = textStorage?.length ?? max(start, end)
        let lower = max(0, min(start, storageLength))
        let upper = max(lower, min(end, storageLength))
        let first = paragraphIndex.paragraphRange(containing: lower)
        let lastOffset = max(lower, upper - 1)
        let last = paragraphIndex.paragraphRange(containing: lastOffset)
        let adjusted = first.union(last)
        sourceFocus = .scoped(adjusted)
        fragmentContext.sourceFocusRange = adjusted
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        guard isEditable else { return }
        if hasMarkedText() || composingParagraph != nil {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        let target = replacementRange.location == NSNotFound
            ? sourceSelectedRange
            : currentDisplayMap.sourceRange(forTextKit: replacementRange)
        performSourceEdit(range: target, replacement: text)
    }

    /// While an input method is composing, marker hiding is suspended in the
    /// composing paragraph so the hybrid and source spaces coincide there and
    /// AppKit's marked-text bookkeeping is exactly right.  A brief reflow at
    /// the start of composition is a fair price for correct CJK input.
    public override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if composingParagraph == nil {
            let caret = sourceSelectedRange.location
            composingParagraph = paragraphRange(containing: caret)
            refreshDisplayMapForComposition()
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    public override func unmarkText() {
        super.unmarkText()
        guard composingParagraph != nil else { return }
        composingParagraph = nil
        refreshDisplayMapForComposition()
    }

    public override func deleteBackward(_ sender: Any?) {
        guard isEditable else { return }
        if hasMarkedText() || composingParagraph != nil { super.deleteBackward(sender); return }
        let selection = sourceSelectedRange
        if selection.length > 0 { performSourceEdit(range: selection, replacement: ""); return }
        guard selection.location > 0, let storage = textStorage else { return }
        performSourceEdit(range: deletionRange(before: selection.location, in: storage), replacement: "")
    }

    public override func deleteForward(_ sender: Any?) {
        guard isEditable else { return }
        if hasMarkedText() || composingParagraph != nil { super.deleteForward(sender); return }
        let selection = sourceSelectedRange
        if selection.length > 0 { performSourceEdit(range: selection, replacement: ""); return }
        guard let storage = textStorage, selection.location < storage.length else { return }
        performSourceEdit(range: deletionRange(after: selection.location, in: storage), replacement: "")
    }

    public override func insertNewline(_ sender: Any?) {
        guard isEditable else { return }
        if hasMarkedText() || composingParagraph != nil { super.insertNewline(sender); return }
        performSourceEdit(range: sourceSelectedRange, replacement: "\n")
    }

    public override func insertTab(_ sender: Any?) {
        guard isEditable else { return }
        performSourceEdit(range: sourceSelectedRange, replacement: "\t")
    }

    public override func paste(_ sender: Any?) {
        guard isEditable else { return }
        let pasteboard = NSPasteboard.general
        guard let payload = markdownPastePayload(from: pasteboard) else { return }
        let range = sourceSelectedRange
        let selection = sourceText(in: range)
        let context = MarkdownSmartPaste.context(for: range, in: parsedDocument, mode: mode)
        let replacement = MarkdownSmartPaste.replacement(
            for: payload, selection: selection, context: context)
        performSourceEdit(range: range, replacement: replacement)
    }

    private func sourceText(in range: NSRange) -> String {
        guard let storage = textStorage, range.location >= 0,
              range.upperBound <= storage.length else { return "" }
        return storage.attributedSubstring(from: range).string
    }

    /// Read the richest useful clipboard flavour first.  URL is intentionally
    /// ahead of HTML/string because browser URL copies commonly advertise all
    /// three and the URL is the user's explicit intent.
    private func markdownPastePayload(from pasteboard: NSPasteboard) -> MarkdownPastePayload? {
        MarkdownSmartPaste.payload(from: pasteboard)
    }

    /// A hidden marker is deleted whole.  Deleting half of `**` would leave
    /// the document in a state the user did not ask for and cannot see.
    private func deletionRange(before caret: Int, in storage: NSTextStorage) -> NSRange {
        if let hidden = currentDisplayMap.substitutionEnding(at: caret), hidden.displayLength == 0 {
            return hidden.sourceRange
        }
        return (storage.string as NSString).rangeOfComposedCharacterSequence(at: caret - 1)
    }

    private func deletionRange(after caret: Int, in storage: NSTextStorage) -> NSRange {
        if let hidden = currentDisplayMap.substitutionStarting(at: caret), hidden.displayLength == 0 {
            return hidden.sourceRange
        }
        return (storage.string as NSString).rangeOfComposedCharacterSequence(at: caret)
    }

    // MARK: - Copy and export (§9.5)

    /// Standard Copy follows the visible surface.  Raw Markdown travels as a
    /// private alternate flavour, so a round-trip within Downright keeps the
    /// source while every other app receives exactly what the user selected.
    public override func copy(_ sender: Any?) {
        let range = sourceSelectedRange
        guard range.length > 0, let storage = textStorage else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let visible = attributedStringForRichTextCopy(range: range)
        let markdownRange = losslessMarkdownRange(forVisibleSourceRange: range)
        let markdown = storage.attributedSubstring(from: markdownRange).string
        pasteboard.declareTypes([.string, .rtf, .downrightMarkdown], owner: nil)
        pasteboard.setString(visible.string, forType: .string)
        pasteboard.setString(markdown, forType: .downrightMarkdown)
        if let data = visible.rtf(
            from: NSRange(location: 0, length: visible.length),
            documentAttributes: [:]
        ) {
            pasteboard.setData(data, forType: .rtf)
        }
    }

    public override func cut(_ sender: Any?) {
        let range = sourceSelectedRange
        guard range.length > 0 else { return }
        copy(sender)
        performSourceEdit(range: range, replacement: "")
    }

    public override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let range = sourceSelectedRange
        guard range.length > 0, let storage = textStorage else { return false }
        pboard.declareTypes([.string, .rtf, .downrightMarkdown], owner: nil)
        let rich = attributedStringForRichTextCopy(range: range)
        pboard.setString(rich.string, forType: .string)
        let markdownRange = losslessMarkdownRange(forVisibleSourceRange: range)
        pboard.setString(
            storage.attributedSubstring(from: markdownRange).string,
            forType: .downrightMarkdown
        )
        if let data = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) {
            pboard.setData(data, forType: .rtf)
        }
        return true
    }

    /// Hidden substitutions at both edges belong to a fully selected visible
    /// span. Include them in Downright's private flavour without changing the
    /// standard visible-text selection exported to other apps.
    private func losslessMarkdownRange(forVisibleSourceRange range: NSRange) -> NSRange {
        var result = range
        var changed = true
        while changed {
            changed = false
            if let leading = currentDisplayMap.substitutions.last(where: {
                $0.replacement == nil && $0.sourceRange.upperBound == result.location
            }) {
                result = NSRange(
                    location: leading.sourceRange.location,
                    length: result.upperBound - leading.sourceRange.location
                )
                changed = true
            }
            if let trailing = currentDisplayMap.substitutions.first(where: {
                $0.replacement == nil && $0.sourceRange.location == result.upperBound
            }) {
                result.length = trailing.sourceRange.upperBound - result.location
                changed = true
            }
        }
        return result
    }

    /// Rendered-selection copy: the display string for the range with
    /// Downright's private attributes stripped and links made real.
    public func attributedStringForRichTextCopy(range: NSRange) -> NSAttributedString {
        guard let storage = textStorage else { return NSAttributedString() }
        let lo = max(0, min(range.location, storage.length))
        let hi = max(lo, min(range.upperBound, storage.length))
        guard hi > lo else { return NSAttributedString() }

        let out = NSMutableAttributedString()
        var cursor = lo
        for sub in currentDisplayMap.substitutions
        where sub.sourceRange.location >= lo && sub.sourceRange.upperBound <= hi {
            if sub.sourceRange.location > cursor {
                out.append(storage.attributedSubstring(
                    from: NSRange(location: cursor, length: sub.sourceRange.location - cursor)))
            }
            if let replacement = sub.replacement { out.append(replacement) }
            cursor = sub.sourceRange.upperBound
        }
        if cursor < hi {
            out.append(storage.attributedSubstring(from: NSRange(location: cursor, length: hi - cursor)))
        }

        let whole = NSRange(location: 0, length: out.length)
        var links: [(NSRange, URL)] = []
        out.enumerateAttribute(.drLink, in: whole) { value, range, _ in
            if let destination = value as? String, let url = URL(string: destination) {
                links.append((range, url))
            }
        }
        for key in MarkdownTextView.privateAttributeKeys { out.removeAttribute(key, range: whole) }
        for (range, url) in links { out.addAttribute(.link, value: url, range: range) }
        return out
    }

    static let privateAttributeKeys: [NSAttributedString.Key] = [
        .drHidden, .drMarker, .drFragment, .drBlock, .drHeading, .drLink, .drPathToken,
        .drPathExists, .drCheckbox, .drChange, .drReference, .drElided, .drGutterMarker,
        .drSearchHit, .drCurrentSearchHit, .drSpeechHighlight, .drInlineCode,
        .drSourceFocus,
    ]

    /// Text spoken by the native speech service. It uses the same substitutions
    /// as rich-text copy, so hidden Markdown markers are not read aloud.
    public func renderedStringForSpeech(sourceRange: NSRange) -> String {
        attributedStringForRichTextCopy(range: sourceRange).string
    }

    /// Convert a range reported by `NSSpeechSynthesizer` back to source space.
    public func sourceRangeForSpeechRange(_ renderedRange: NSRange, within sourceRange: NSRange) -> NSRange? {
        guard renderedRange.location >= 0, renderedRange.length >= 0 else { return nil }
        let start = currentDisplayMap.textKitOffset(forSource: sourceRange.location)
        let textKitRange = NSRange(location: start + renderedRange.location, length: renderedRange.length)
        let mapped = currentDisplayMap.sourceRange(forTextKit: textKitRange)
        guard mapped.location >= sourceRange.location, mapped.upperBound <= sourceRange.upperBound else { return nil }
        return mapped
    }

    /// §9.5: export the selection as an image, for pasting a rendered table or
    /// diagram into a message.  Captures what is actually on screen, so what
    /// you paste is what you saw.
    public func imageForSelection(_ range: NSRange) -> NSImage? {
        guard let start = rect(forOffset: range.location), let end = rect(forOffset: range.upperBound) else {
            return nil
        }
        var union = start.union(end)
        union.origin.x = 0
        union.size.width = bounds.width
        union = union.insetBy(dx: 0, dy: -6)
        guard union.width > 1, union.height > 1,
              let rep = bitmapImageRepForCachingDisplay(in: union) else { return nil }
        cacheDisplay(in: union, to: rep)
        let image = NSImage(size: union.size)
        image.addRepresentation(rep)
        return image
    }
}
