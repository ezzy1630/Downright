import AppKit
import MarkdownCore

// §7.1 — the pointer is the primary interaction path, and every capability
// here is reachable without touching the keyboard.  Read mode has no insertion
// caret and *all* of this still works.
extension MarkdownTextView {
    public func activateLinkAtCaret() -> Bool {
        guard let hit = linkAtCaret() else { return false }
        markdownDelegate?.markdownTextView(
            self,
            didActivateLink: hit.destination,
            at: hit.range,
            modifiers: []
        )
        return true
    }

    public func moveToLink(forward: Bool) -> Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        var links: [NSRange] = []
        storage.enumerateAttribute(
            .drLink,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            if value is String { links.append(range) }
        }
        guard !links.isEmpty else { return false }
        let caret = sourceSelectedRange.location
        let target: NSRange
        if forward {
            target = links.first { $0.location > caret } ?? links[0]
        } else {
            target = links.last { $0.location < caret } ?? links[links.count - 1]
        }
        setSourceSelectedRanges([NSRange(location: target.location, length: 0)])
        scroll(toOffset: target.location, position: .visible, animated: true)
        return true
    }

    private func linkAtCaret() -> (destination: String, range: NSRange)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let caret = min(sourceSelectedRange.location, storage.length - 1)
        for offset in [caret, max(0, caret - 1)] {
            var range = NSRange()
            if let destination = storage.attribute(
                .drLink,
                at: offset,
                longestEffectiveRange: &range,
                in: NSRange(location: 0, length: storage.length)
            ) as? String {
                return (destination, range)
            }
        }
        return nil
    }


    private struct CheckboxHit {
        var markOffset: Int
        var checked: Bool
        var blockRange: NSRange
    }

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
        attribute(key, at: point, sourceOffset: sourceOffset(at: point))
    }

    /// Attribute under a point when the caller already resolved its source
    /// offset. Inline targets need one extra check: TextKit returns the nearest
    /// insertion boundary, so the usual `offset - 1` fallback can otherwise
    /// make the whitespace immediately after a link activate that link.
    private func attribute(
        _ key: NSAttributedString.Key,
        at point: NSPoint,
        sourceOffset offset: Int
    ) -> (value: Any, range: NSRange)? {
        let pointSensitive = key == .drLink || key == .drPathToken || key == .drReference
        guard let storage = textStorage, storage.length > 0 else { return nil }
        for candidate in [offset, offset - 1]
            where candidate >= 0 && candidate < storage.length {
            guard let hit = attributeValue(key, atSourceOffset: candidate) else { continue }
            if pointSensitive, !renderedTextContains(point, sourceRange: hit.range) { continue }
            return hit
        }
        return nil
    }

    /// The same hit test against an offset the caller already resolved.
    ///
    /// `sourceOffset(at:)` forces a TextKit hit test, and hover asks several
    /// independent questions about one pointer position — fragment, link,
    /// footnote, path, checkbox.  Resolving the offset once per event and
    /// sharing it is the difference between one hit test per mouse move and
    /// six, which is what made the pointer lag on a long document (§7.1, §12).
    func attribute(
        _ key: NSAttributedString.Key,
        atSourceOffset offset: Int
    ) -> (value: Any, range: NSRange)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        for candidate in [offset, offset - 1] where candidate >= 0 && candidate < storage.length {
            if let hit = attributeValue(key, atSourceOffset: candidate) { return hit }
        }
        return nil
    }

    private func attributeValue(
        _ key: NSAttributedString.Key,
        atSourceOffset offset: Int
    ) -> (value: Any, range: NSRange)? {
        guard let storage = textStorage, storage.length > 0,
              offset >= 0, offset < storage.length else { return nil }
        var range = NSRange(location: 0, length: 0)
        guard let value = storage.attribute(key, at: offset, effectiveRange: &range) else { return nil }
        return (value, range)
    }

    func fragmentPayload(at point: NSPoint) -> (payload: FragmentPayload, range: NSRange)? {
        fragmentPayload(atSourceOffset: sourceOffset(at: point))
    }

    func fragmentPayload(atSourceOffset offset: Int) -> (payload: FragmentPayload, range: NSRange)? {
        guard let hit = attribute(.drFragment, atSourceOffset: offset),
              let payload = hit.value as? FragmentPayload else { return nil }
        return (payload, hit.range)
    }

    // MARK: - Hover (§7.1)

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // Keep the chip alive while the pointer crosses into the adjacent
        // gutter.  AppKit sends `mouseExited` before the rail's tracking area
        // receives `mouseEntered`; clearing here made the control disappear
        // for one frame and discarded the heading target mid-handoff.
        if let rail = gutterRail,
           rail.window === window,
           rail.bounds.contains(rail.convert(event.locationInWindow, from: nil)) {
            return
        }
        clearHoverState()
    }

    private func updateHover(at point: NSPoint) {
        var needsRedraw = false
        // One TextKit hit test answers every question this method asks.
        let offset = sourceOffset(at: point)
        let payload = fragmentPayload(atSourceOffset: offset)?.payload
        let linkHit = attribute(.drLink, at: point, sourceOffset: offset)

        // Code blocks reveal a copy button; images reveal that they open; tables
        // zebra the row under the pointer (§7.1, §11.3).
        let hoveredFragment: NSRange?
        switch payload?.kind {
        case .codeBlock, .collapsedCodeBlock, .image, .frontMatter: hoveredFragment = payload?.sourceRange
        default: hoveredFragment = nil
        }
        if fragmentContext.hoveredFragmentRange != hoveredFragment {
            fragmentContext.hoveredFragmentRange = hoveredFragment
            needsRedraw = true
        }

        var rowRange: NSRange?
        if payload?.kind == .table, let table = payload?.tableData {
            rowRange = table.rows.first { !$0.isHeader && $0.range.contains(offset: offset) }?.range
        }
        if fragmentContext.hoveredTableRow != rowRange {
            fragmentContext.hoveredTableRow = rowRange
            needsRedraw = true
        }

        // Hovering a heading puts an anchor glyph in the gutter (§7.1).
        let headingIndex = parsedDocument.headings.firstIndex { $0.range.contains(offset: offset) }
        if hoveredHeadingIndex != headingIndex {
            hoveredHeadingIndex = headingIndex
            gutterRail?.needsDisplay = true
        }

        // The cursor is owned by `cursorUpdate`, which is AppKit's sanctioned
        // path and cooperates with the text view's own i-beam cursor rect.
        // Setting it from a mouse-moved handler as well made it flicker.

        // Links underline under the pointer (§7.1).  Images carry `.drLink`
        // for their source too, but an image has no text to underline.
        var linkRange: NSRange?
        if let linkHit, linkHit.range.length > 0, payload?.kind != .image {
            linkRange = linkHit.range
        } else if let pathHit = attribute(.drPathToken, at: point, sourceOffset: offset),
                  pathHit.range.length > 0,
                  attribute(.drPathExists, atSourceOffset: offset)?.value as? Bool == true {
            // A resolvable path is interactive, so it answers the pointer the
            // way every other interactive run does — on hover.  It used to say
            // so permanently, with an accent bar down its leading edge, which
            // on a dark ground is indistinguishable from an insertion point
            // parked mid-sentence: a caret that never blinks and never moves,
            // once per path, in prose that is full of them.
            linkRange = pathHit.range
        }
        if linkRange != hoveredLinkRange {
            hoveredLinkRange = linkRange
            needsDisplay = true
        }

        let nextToolTip: String?
        if payload?.kind == .image {
            // The alt text is the one thing about an image the reader cannot
            // see, and it doubles as the cue that the image opens.
            let alt = payload?.detail.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            nextToolTip = alt.isEmpty ? nil : alt
        } else if payload?.kind == .frontMatter {
            nextToolTip = "Edit front matter"
        } else if let hit = attribute(.drReference, at: point, sourceOffset: offset),
                  let identifier = hit.value as? String,
                  let footnote = parsedDocument.footnotes[identifier] {
            nextToolTip = parsedDocument.substring(footnote.contentRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let destination = linkHit?.value as? String {
            nextToolTip = destination
        } else {
            nextToolTip = nil
        }
        if toolTip != nextToolTip { toolTip = nextToolTip }

        if needsRedraw { needsDisplay = true }
    }

    func clearHoverState() {
        fragmentContext.hoveredFragmentRange = nil
        fragmentContext.hoveredTableRow = nil
        hoveredHeadingIndex = nil
        hoveredLinkRange = nil
        toolTip = nil
        needsDisplay = true
        gutterRail?.needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// One definition of "the pointer is over something that responds", shared
    /// by the cursor and by hover feedback so they can never disagree.
    private func hasInteractiveTarget(at point: NSPoint) -> Bool {
        // The checkbox probe samples its own x inside the measure, so it keeps
        // its own hit test; every remaining question shares one.
        if semanticCheckbox(at: point) != nil { return true }
        let offset = sourceOffset(at: point)
        if mode == .live {
            // Rendered targets are actionable on a normal click. Option-click
            // still falls through to the editor for caret placement.
            return attribute(.drCheckbox, at: point, sourceOffset: offset) != nil
                || attribute(.drLink, at: point, sourceOffset: offset) != nil
                || attribute(.drReference, at: point, sourceOffset: offset) != nil
                || attribute(.drPathToken, at: point, sourceOffset: offset) != nil
                || fragmentPayload(atSourceOffset: offset)?.payload.kind == .image
                || fragmentPayload(atSourceOffset: offset)?.payload.kind == .frontMatter
        }
        guard mode == .read else { return false }
        return attribute(.drLink, at: point, sourceOffset: offset) != nil
            || attribute(.drReference, at: point, sourceOffset: offset) != nil
            || attribute(.drPathToken, at: point, sourceOffset: offset) != nil
            || fragmentPayload(atSourceOffset: offset)?.payload.kind == .image
            || fragmentPayload(atSourceOffset: offset)?.payload.kind == .frontMatter
    }

    private func setPointerCursor(interactive: Bool) {
        if interactive {
            NSCursor.pointingHand.set()
        } else if isEditable {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// Confirms a toggle with a short pop, unless the user asked for less
    /// motion — the box already changes to a filled accent tick, which is
    /// answer enough on its own.
    private func confirmCheckboxToggle(in blockRange: NSRange, checked: Bool) {
        guard !styleSheet.reduceMotion else {
            setNeedsDisplay(pulseInvalidationRect(for: [blockRange]))
            return
        }
        fragmentContext.beginCheckboxPulse(blockRange, checked: checked)
        driveCheckboxPulseRedraw()
    }

    /// Keeps redrawing while any checkbox pulse is live, then parks the
    /// driver.  The pop is drawn by the fragment, not stored as text
    /// attributes, so the only thing this has to do is ask for frames; halving
    /// the pulse-started members of the clock is done by the shared document
    /// driver's `advance` hook, which also carries the scroll inertia coast.
    private func driveCheckboxPulseRedraw() {
        armMotionDriver()
    }

    /// The area a pulsing ornament can reach: the blocks holding the boxes,
    /// widened into the hanging indent the ornament is drawn in.
    func pulseInvalidationRect(for ranges: [NSRange]) -> NSRect {
        var union = NSRect.zero
        for range in ranges {
            guard let start = rect(forOffset: range.location) else { continue }
            let end = rect(forOffset: max(range.location, range.upperBound - 1)) ?? start
            union = union.isEmpty ? start.union(end) : union.union(start.union(end))
        }
        guard !union.isEmpty else { return bounds }
        union.origin.x = bounds.minX
        union.size.width = bounds.width
        return union.insetBy(dx: 0, dy: -RenderMetrics.verticalInset)
    }

    public override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setPointerCursor(interactive: hasInteractiveTarget(at: point))
    }

    // MARK: - Click (§7.1)

    /// Whether a single click is eligible to follow a rendered target. The
    /// actual activation waits until AppKit finishes tracking the gesture so a
    /// drag can still select link text and double/triple-clicks can still make
    /// words or paragraphs.
    private func clickActivates(
        _: NSRange,
        modifiers: NSEvent.ModifierFlags,
        clickCount: Int
    ) -> Bool {
        guard mode != .source else { return false }
        guard clickCount == 1 else { return false }
        let editingModifiers: NSEvent.ModifierFlags = [.option, .shift, .control]
        return mode == .read || modifiers.intersection(editingModifiers).isEmpty
    }

    public override func mouseDown(with event: NSEvent) {
        interruptAnimatedScroll()
        let point = convert(event.locationInWindow, from: nil)
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var activateAfterTracking: (() -> Void)?

        if sourceFocusDoneRect?.insetBy(dx: -4, dy: -4).contains(point) == true {
            clearSourceFocus()
            return
        }

        if handleCodeBlockChrome(at: point) { return }

        if mode != .source,
           let hit = fragmentPayload(at: point),
           hit.payload.kind == .frontMatter,
           clickActivates(
               hit.payload.sourceRange,
               modifiers: modifiers,
               clickCount: event.clickCount
           ) {
            markdownDelegate?.markdownTextView(
                self,
                didActivateFrontMatterAt: hit.payload.sourceRange
            )
            return
        }

        if mode != .source, let hit = attribute(.drElided, at: point) {
            expandElision(at: hit.range.location)
            return
        }

        // The ornament lives in the hanging indent, outside the hidden source
        // marker's glyph rect. Hit-test the same 28pt control that is drawn,
        // so Document mode does not require a trip to Source. In Source mode
        // the literal `[ ]` remains ordinary editable text.
        if let hit = semanticCheckbox(at: point) {
            guard event.clickCount == 1 else { return }
            markdownDelegate?.markdownTextView(self, didToggleCheckboxAtMarkOffset: hit.markOffset)
            confirmCheckboxToggle(in: hit.blockRange, checked: !hit.checked)
            return
        }

        if mode != .source, let hit = attribute(.drCheckbox, at: point) {
            guard event.clickCount == 1 else { return }
            let wasChecked = (hit.value as? Bool) ?? false
            markdownDelegate?.markdownTextView(self, didToggleCheckboxAtMarkOffset: hit.range.location)
            if let blockRange = fragmentPayload(at: point)?.payload.sourceRange {
                confirmCheckboxToggle(in: blockRange, checked: !wasChecked)
            }
            return
        }

        if let hit = attribute(.drPathToken, at: point), let token = hit.value as? PathToken,
           clickActivates(hit.range, modifiers: modifiers, clickCount: event.clickCount) {
            activateAfterTracking = { [weak self] in
                guard let self else { return }
                self.markdownDelegate?.markdownTextView(
                    self, didActivatePathToken: token, at: hit.range
                )
            }
        }
        if let hit = attribute(.drLink, at: point), let destination = hit.value as? String,
           clickActivates(hit.range, modifiers: modifiers, clickCount: event.clickCount) {
            activateAfterTracking = { [weak self] in
                guard let self else { return }
                self.markdownDelegate?.markdownTextView(
                    self,
                    didActivateLink: destination,
                    at: hit.range,
                    modifiers: modifiers
                )
            }
        }
        if let hit = attribute(.drReference, at: point),
           let identifier = hit.value as? String,
           let footnote = parsedDocument.footnotes[identifier],
           clickActivates(hit.range, modifiers: modifiers, clickCount: event.clickCount) {
            activateAfterTracking = { [weak self] in
                guard let self else { return }
                self.markdownDelegate?.markdownTextView(self, didNavigateTo: footnote.range.location)
                // `.visible`, not `.center`: centring drags the page even when
                // the definition is already on screen, which is the "click
                // teleports the camera" jolt. Reveal only when the target is
                // actually off screen.
                self.scroll(toOffset: footnote.range.location, position: .visible, animated: true)
            }
        }
        if let payload = fragmentPayload(at: point)?.payload, payload.kind == .image,
           clickActivates(
               payload.sourceRange,
               modifiers: modifiers,
               clickCount: event.clickCount
           ) {
            activateAfterTracking = { [weak self] in
                guard let self else { return }
                // §7.1: click an image → lightbox. The render package owns no
                // windows, so it reports and the app presents.
                self.markdownDelegate?.markdownTextView(
                    self,
                    didActivateImage: payload.detail,
                    at: payload.sourceRange
                )
            }
        }

        // A plain click in a fence's padding aims at the code, not at the
        // invisible fence.  Shift-, option- and multi-clicks are deliberate
        // selection gestures and go to `super` untouched.
        if event.clickCount == 1, modifiers.isEmpty,
           let redirect = redirectedCodeFenceCaret(at: point) {
            window?.makeFirstResponder(self)
            setSourceSelectedRanges([NSRange(location: redirect, length: 0)])
            handleSelectionChanged(allowTypewriterScrolling: false)
            return
        }

        // `super` owns the whole click/drag gesture.  Make the target first
        // responder explicitly; relying on the window's default mouse routing
        // leaves a split-pane click visually correct but sends the next key to
        // the other pane on some AppKit layouts.  Delay marker reveal until
        // it resolves to a caret or a selection, so selection never causes a
        // transient source flash or moves the glyphs under the pointer.
        window?.makeFirstResponder(self)
        isTrackingMouseSelection = true
        suppressesCaretReveal = true
        super.mouseDown(with: event)
        isTrackingMouseSelection = false
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
        handleSelectionChanged(allowTypewriterScrolling: false)
        if sourceSelectedRange.length == 0 {
            activateAfterTracking?()
        }
    }

    private func semanticCheckbox(at point: NSPoint) -> CheckboxHit? {
        guard mode != .source else { return nil }
        // Called from every mouse-moved event, and `rect(forOffset:)` forces
        // TextKit layout — so walking every task in the document made the
        // pointer visibly lag on exactly the documents this app is for
        // (agent checklists).  Only a task occupying the pointer's own line
        // can be under it, so resolve that line once and skip the rest.
        // Sample inside the measure: the ornament itself lives in the hanging
        // indent, where there are no glyphs to hit-test against.
        let columnLeft = textContainerOrigin.x
        let sampleX = min(max(point.x, columnLeft + 1), columnLeft + styleSheet.measureWidth - 1)
        let pointOffset = sourceOffset(at: NSPoint(x: sampleX, y: point.y))
        let bodySize = styleSheet.bodyFont().pointSize
        for task in parsedDocument.tasks {
            if let focus = sourceFocus.range,
               focus.contains(offset: task.markRange.location) {
                continue
            }
            guard task.contentRange.contains(offset: pointOffset)
                || task.markRange.contains(offset: pointOffset) else { continue }
            guard let textRect = rect(forOffset: task.contentRange.location) else { continue }
            let centreY = textRect.minY + min(styleSheet.lineHeight, textRect.height) * 0.44
            let target = ListOrnamentFragment.taskHitRect(
                textEdge: textRect.minX,
                centreY: centreY,
                bodySize: bodySize
            )
            guard target.contains(point) else { continue }
            let block = parsedDocument.root.block(at: task.markRange.location)
            return CheckboxHit(
                markOffset: task.markRange.location,
                checked: task.isChecked,
                blockRange: block?.range ?? task.contentRange
            )
        }
        return nil
    }

    public override func cancelOperation(_ sender: Any?) {
        guard sourceFocus != .none else {
            super.cancelOperation(sender)
            return
        }
        clearSourceFocus()
    }

    /// Where a click on a fenced block's chrome rows should really put the caret.
    ///
    /// The fence lines are kept in the storage on purpose (§11.3) — they are
    /// what the band's padding is made of, and keeping them means ⌘C still
    /// yields a complete fenced block.  But in Document mode their glyphs are
    /// suppressed, and AppKit happily resolves a click in that padding to a
    /// character position part-way along an invisible ```` ```swift ````.  The
    /// caret then blinks in empty space above the code with nothing under it,
    /// and the next keystroke edits a fence the reader cannot see.
    ///
    /// Aim at the code instead: the top row lands on the first code line, the
    /// bottom row on the end of the last one.  Source mode and a revealed
    /// source-focus scope both show the fences, so there the click is honest
    /// and stands.
    private func redirectedCodeFenceCaret(at point: NSPoint) -> Int? {
        guard mode != .source, let storage = textStorage, storage.length > 0 else { return nil }
        guard let hit = fragmentPayload(at: point), hit.payload.kind == .codeBlock else { return nil }
        let block = NSIntersectionRange(
            hit.payload.sourceRange, NSRange(location: 0, length: storage.length)
        )
        guard block.length > 0 else { return nil }
        if let focus = sourceFocus.range, NSIntersectionRange(focus, block).length > 0 { return nil }

        let text = storage.string as NSString
        let opening = text.lineRange(for: NSRange(location: block.location, length: 0))
        let closing = text.lineRange(for: NSRange(location: block.upperBound - 1, length: 0))
        // A block whose fences share a line has no code row to redirect to.
        guard opening.location != closing.location else { return nil }

        let offset = sourceOffset(at: point)
        if offset < opening.upperBound {
            return min(opening.upperBound, block.upperBound)
        }
        if offset >= closing.location {
            return max(block.location, closing.location - 1)
        }
        return nil
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

        // `payload.sourceRange` can point past the end of the storage in the
        // window between an edit and the async parse committing — a large
        // deletion shrinks the buffer before the parse lands, and `attribute(at:)`
        // beyond the storage raises an uncatchable NSRangeException.  Every
        // other consumer of this storage clamps; do the same here.
        guard let storage = textStorage, storage.length > 0 else { return false }
        var styleLocation = payload.sourceRange.location
        styleLocation = min(max(0, styleLocation), storage.length - 1)
        // `firstLineHeadIndent`, matching `CodeBlockFragment.bandRect`: a
        // wrapped code row hangs by a continuation indent, and `headIndent`
        // would pull this reconstructed band — and the copy target inside it —
        // two columns left of the one on screen.
        let indent = max(
            0,
            ((storage.attribute(.paragraphStyle, at: styleLocation, effectiveRange: nil)
                as? NSParagraphStyle)?.firstLineHeadIndent ?? RenderMetrics.codeInsetX)
                - RenderMetrics.codeInsetX
        )
        let band = CGRect(
            x: indent,
            y: chrome.minY,
            width: max(1, columnWidth - indent),
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
        // Tilde fences are as valid as backtick fences and the parser accepts
        // both, so the pasteboard has to recognise both.
        func isFence(_ line: String?) -> Bool {
            guard let trimmed = line?.trimmingCharacters(in: .whitespaces),
                  let marker = trimmed.first, marker == "`" || marker == "~" else { return false }
            return trimmed.prefix(while: { $0 == marker }).count >= 3
        }
        if isFence(body.first) { body.removeFirst() }
        if isFence(body.last) { body.removeLast() }
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
        if let hit = attribute(.drPathToken, at: point, sourceOffset: offset), let token = hit.value as? PathToken {
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
        if let hit = attribute(.drLink, at: point, sourceOffset: offset), let destination = hit.value as? String {
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
    public func performSourceEdit(
        range: NSRange,
        replacement: String,
        provenance: String = "Edit"
    ) -> Bool {
        guard isEditable, let storage = textStorage else { return false }
        let clamped = NSRange(location: max(0, min(range.location, storage.length)),
                              length: max(0, min(range.length, storage.length - min(range.location, storage.length))))
        // Capture before `didChangeText()` can run AppKit's implicit
        // make-caret-visible path. Capturing after the mutation records the
        // teleported camera as if it were intentional.
        let viewportAnchor = captureViewportAnchor()
        // AppKit's `shouldChangeText` coalesces into the undo manager. Synthetic
        // key events (and a few edge focus paths) can arrive with no open group;
        // open one so typing never traps on `NSUndoManager` state.
        let undo = undoManager
        let openedUndoGroup = undo.map { $0.groupingLevel == 0 } ?? false
        if openedUndoGroup { undo?.beginUndoGrouping() }
        defer { if openedUndoGroup { undo?.endUndoGrouping() } }
        guard shouldChangeText(in: clamped, replacementString: replacement) else { return false }
        // Structural zoom is a reading projection. Editing through an elided
        // projection makes nearby paragraphs appear and disappear around the
        // caret, so the first mutation returns to the complete document.
        if zoomLevel != .everything { zoomLevel = .everything }

        let oldParagraphs = paragraphIndex
        let oldHiddenRanges = currentDisplayMap.baseHiddenRangesForEditProjection
        let deletedText = storage.attributedSubstring(from: clamped).string
        let inserted = (replacement as NSString).length
        let projectedViewportAnchor = projectViewportAnchor(
            viewportAnchor, across: clamped, insertedLength: inserted
        )
        let preservesParagraphStructure = !containsParagraphSeparator(deletedText)
            && !containsParagraphSeparator(replacement)
        projectFragmentPayloads(across: clamped, insertedLength: inserted)
        lastMutationProvenance = provenance
        beginSourceEdit()
        storage.replaceCharacters(in: clamped, with: replacement)
        rebuildParagraphIndex()
        adjustScopedSourceFocus(forEdit: clamped, insertedLength: inserted)
        projectDisplayMapAcrossEdit(
            clamped,
            insertedLength: inserted,
            oldParagraphs: oldParagraphs,
            oldHiddenRanges: oldHiddenRanges,
            preservesParagraphStructure: preservesParagraphStructure
        )
        didChangeText()
        endSourceEdit()

        markdownDelegate?.markdownTextView(self, didEdit: clamped, delta: inserted - clamped.length)
        shouldFollowCaretAfterLocalEdit = true
        localEditViewportAnchor = projectedViewportAnchor
        setSourceSelectedRanges([NSRange(location: clamped.location + inserted, length: 0)])
        handleSelectionChanged(preservingViewport: projectedViewportAnchor)
        return true
    }

    /// Keep reference-valued fragment metadata aligned with the storage while
    /// the parser works on its immutable snapshot. Attribute runs move with an
    /// `NSTextStorage` edit; their payload objects must be moved explicitly.
    private func projectFragmentPayloads(across range: NSRange, insertedLength: Int) {
        guard let storage = textStorage, storage.length > 0 else { return }
        var seen = Set<ObjectIdentifier>()
        storage.enumerateAttribute(
            .drFragment,
            in: NSRange(
                location: min(range.location, storage.length),
                length: max(0, storage.length - min(range.location, storage.length))
            )
        ) { value, _, _ in
            guard let payload = value as? FragmentPayload else { return }
            let identity = ObjectIdentifier(payload)
            guard seen.insert(identity).inserted else { return }
            payload.projectSourceRanges(across: range, insertedLength: insertedLength)
        }
    }

    private func containsParagraphSeparator(_ string: String) -> Bool {
        string.unicodeScalars.contains {
            switch $0.value {
            case 0x0A, 0x0D, 0x0085, 0x2028, 0x2029:
                return true
            default:
                return false
            }
        }
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
            let openedUndoGroup = undoManager?.groupingLevel == 0
            if openedUndoGroup { undoManager?.beginUndoGrouping() }
            defer { if openedUndoGroup { undoManager?.endUndoGrouping() } }
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        let target = replacementRange.location == NSNotFound
            ? sourceSelectedRange
            : currentDisplayMap.sourceRange(forTextKit: replacementRange)
        performSourceEdit(range: target, replacement: text)
    }

    /// Select All is a source operation even in rendered Document mode. The
    /// display map intentionally omits Markdown markers, so AppKit's default
    /// implementation can select only the visible title/body and leave `##`,
    /// emphasis delimiters, task markers, or link syntax outside the range.
    /// Replacing that partial selection is what turned `## xyzxyz` into
    /// `## ## xyzxyz` in the real editor.
    public override func selectAll(_ sender: Any?) {
        guard isEditable, let storage = textStorage else {
            super.selectAll(sender)
            return
        }
        setSourceSelectedRanges([
            NSRange(location: 0, length: storage.length)
        ])
        handleSelectionChanged(allowTypewriterScrolling: false)
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
        // NSTextView registers marked-text replacement with its undo manager.
        // Downright disables event grouping so source commands own exact undo
        // boundaries; IME must therefore supply the group AppKit expects.
        let openedUndoGroup = undoManager?.groupingLevel == 0
        if openedUndoGroup { undoManager?.beginUndoGrouping() }
        defer { if openedUndoGroup { undoManager?.endUndoGrouping() } }
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

    public override func deleteBackwardByDecomposingPreviousCharacter(_ sender: Any?) {
        deleteBackward(sender)
    }

    public override func deleteWordBackward(_ sender: Any?) {
        guard isEditable else { return }
        if hasMarkedText() || composingParagraph != nil {
            super.deleteWordBackward(sender)
            return
        }
        let selection = sourceSelectedRange
        if selection.length > 0 {
            performSourceEdit(range: selection, replacement: "")
            return
        }
        guard let storage = textStorage,
              let range = wordDeletionRange(before: selection.location, in: storage) else { return }
        performSourceEdit(range: range, replacement: "")
    }

    public override func deleteWordForward(_ sender: Any?) {
        guard isEditable else { return }
        if hasMarkedText() || composingParagraph != nil {
            super.deleteWordForward(sender)
            return
        }
        let selection = sourceSelectedRange
        if selection.length > 0 {
            performSourceEdit(range: selection, replacement: "")
            return
        }
        guard let storage = textStorage,
              let range = wordDeletionRange(after: selection.location, in: storage) else { return }
        performSourceEdit(range: range, replacement: "")
    }

    public override func deleteToBeginningOfLine(_ sender: Any?) {
        deleteToBoundary(sender, paragraph: false, beginning: true)
    }

    public override func deleteToEndOfLine(_ sender: Any?) {
        deleteToBoundary(sender, paragraph: false, beginning: false)
    }

    public override func deleteToBeginningOfParagraph(_ sender: Any?) {
        deleteToBoundary(sender, paragraph: true, beginning: true)
    }

    public override func deleteToEndOfParagraph(_ sender: Any?) {
        deleteToBoundary(sender, paragraph: true, beginning: false)
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
        applyPaste(mode: .smart)
    }

    /// Explicitly prefer Markdown semantics even when the selection is in a
    /// literal block. This is the command counterpart to Downright's private
    /// lossless clipboard flavour.
    @objc public func pasteAsMarkdown(_ sender: Any?) {
        applyPaste(mode: .markdown)
    }

    /// Insert only the source's visible words, dropping formatting and table
    /// conversion. This mirrors AppKit's Paste and Match Style action.
    @objc public func pasteAndMatchStyle(_ sender: Any?) {
        applyPaste(mode: .matchStyle)
    }

    private func applyPaste(mode pasteMode: MarkdownPasteMode) {
        guard isEditable else { return }
        let pasteboard = NSPasteboard.general
        guard let payload = markdownPastePayload(from: pasteboard, mode: pasteMode) else { return }
        if case .image = payload {
            // An unnamed bitmap has no honest Markdown destination until the
            // document owner chooses an asset path. Never replace a selection
            // with guessed placeholder text.
            NSSound.beep()
            return
        }
        let range = sourceSelectedRange
        let selection = sourceText(in: range)
        let context = MarkdownSmartPaste.context(for: range, in: parsedDocument, mode: mode)
        let replacement = MarkdownSmartPaste.replacement(
            for: payload, selection: selection, context: context, mode: pasteMode)
        let provenance: String
        switch pasteMode {
        case .smart: provenance = "Paste"
        case .markdown: provenance = "Paste as Markdown"
        case .matchStyle: provenance = "Paste and Match Style"
        }
        performSourceEdit(range: range, replacement: replacement, provenance: provenance)
    }

    private func sourceText(in range: NSRange) -> String {
        guard let storage = textStorage, range.location >= 0,
              range.upperBound <= storage.length else { return "" }
        return storage.attributedSubstring(from: range).string
    }

    private func deleteToBoundary(
        _ sender: Any?,
        paragraph: Bool,
        beginning: Bool
    ) {
        guard isEditable else { return }
        if hasMarkedText() || composingParagraph != nil {
            if paragraph {
                if beginning {
                    super.deleteToBeginningOfParagraph(sender)
                } else {
                    super.deleteToEndOfParagraph(sender)
                }
            } else if beginning {
                super.deleteToBeginningOfLine(sender)
            } else {
                super.deleteToEndOfLine(sender)
            }
            return
        }
        let selection = sourceSelectedRange
        if selection.length > 0 {
            performSourceEdit(range: selection, replacement: "")
            return
        }
        guard let storage = textStorage else { return }
        let string = storage.string as NSString
        let caret = min(max(selection.location, 0), string.length)
        let containing = NSRange(location: caret, length: 0)
        let boundary = paragraph ? string.paragraphRange(for: containing) : string.lineRange(for: containing)
        let range: NSRange
        if beginning {
            range = NSRange(location: boundary.location, length: caret - boundary.location)
        } else {
            let end = paragraph
                ? boundary.upperBound
                : RangeSet.contentEnd(ofParagraph: boundary, text: string)
            range = NSRange(location: caret, length: end - caret)
        }
        guard range.length > 0 else { return }
        performSourceEdit(range: range, replacement: "")
    }

    /// AppKit's word commands are expressed in the text system's hybrid
    /// offsets. Resolve the word in source space so hidden Markdown markers
    /// never make Option-Delete edit the wrong byte range.
    private func wordDeletionRange(before caret: Int, in storage: NSTextStorage) -> NSRange? {
        let string = storage.string as NSString
        let clampedCaret = min(max(caret, 0), string.length)
        guard clampedCaret > 0 else { return nil }

        var word: NSRange?
        string.enumerateSubstrings(
            in: NSRange(location: 0, length: clampedCaret),
            options: [.byWords, .reverse]
        ) { _, range, _, stop in
            word = range
            stop.pointee = true
        }
        if let word, word.location < clampedCaret {
            return NSRange(location: word.location, length: clampedCaret - word.location)
        }
        return deletionRange(before: clampedCaret, in: storage)
    }

    private func wordDeletionRange(after caret: Int, in storage: NSTextStorage) -> NSRange? {
        let string = storage.string as NSString
        let clampedCaret = min(max(caret, 0), string.length)
        guard clampedCaret < string.length else { return nil }

        var word: NSRange?
        string.enumerateSubstrings(
            in: NSRange(location: clampedCaret, length: string.length - clampedCaret),
            options: [.byWords]
        ) { _, range, _, stop in
            word = range
            stop.pointee = true
        }
        if let word {
            return NSRange(location: clampedCaret, length: word.upperBound - clampedCaret)
        }
        return deletionRange(after: clampedCaret, in: storage)
    }

    /// Resolve clipboard flavour according to the invoked command. Ordinary
    /// paste remains literal; rich conversion is an explicit choice.
    private func markdownPastePayload(
        from pasteboard: NSPasteboard,
        mode: MarkdownPasteMode
    ) -> MarkdownPastePayload? {
        MarkdownSmartPaste.payload(from: pasteboard, mode: mode)
    }

    /// A hidden marker is deleted whole.  Deleting half of `**` would leave
    /// the document in a state the user did not ask for and cannot see.
    private func deletionRange(before caret: Int, in storage: NSTextStorage) -> NSRange {
        // Layout maps keep hidden markers as same-length joiners (`displayLength`
        // > 0); semantic hiding is still `isHidden`.
        if let hidden = currentDisplayMap.substitutionEnding(at: caret), hidden.isHidden {
            return hidden.sourceRange
        }
        return (storage.string as NSString).rangeOfComposedCharacterSequence(at: caret - 1)
    }

    private func deletionRange(after caret: Int, in storage: NSTextStorage) -> NSRange {
        if let hidden = currentDisplayMap.substitutionStarting(at: caret), hidden.isHidden {
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
        let visible = exportableAttributedString(range: range)
        let markdownRange = losslessMarkdownRange(forVisibleSourceRange: range)
        let markdown = storage.attributedSubstring(from: markdownRange).string
        pasteboard.declareTypes([.string, .rtf, .html, .downrightMarkdown], owner: nil)
        pasteboard.setString(visible.string, forType: .string)
        pasteboard.setString(markdown, forType: .downrightMarkdown)
        pasteboard.setString(ClipboardSemanticHTML.render(markdown: markdown), forType: .html)
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
        pboard.declareTypes([.string, .rtf, .html, .downrightMarkdown], owner: nil)
        let rich = exportableAttributedString(range: range)
        pboard.setString(rich.string, forType: .string)
        let markdownRange = losslessMarkdownRange(forVisibleSourceRange: range)
        pboard.setString(
            storage.attributedSubstring(from: markdownRange).string,
            forType: .downrightMarkdown
        )
        pboard.setString(
            ClipboardSemanticHTML.render(
                markdown: storage.attributedSubstring(from: markdownRange).string
            ),
            forType: .html
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
                $0.isHidden && $0.sourceRange.upperBound == result.location
            }) {
                result = NSRange(
                    location: leading.sourceRange.location,
                    length: result.upperBound - leading.sourceRange.location
                )
                changed = true
            }
            if let trailing = currentDisplayMap.substitutions.first(where: {
                $0.isHidden && $0.sourceRange.location == result.upperBound
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

    /// Characters the display map inserts purely to hold TextKit's coordinate
    /// space level with the source: word joiners standing in for hidden
    /// markers, and the zero-width space that joins a hard-wrapped line.  They
    /// are invisible on screen and meaningless outside Downright, so anything
    /// leaving the app has to shed them — a paste into a terminal, a diff, a
    /// commit message or a search box would otherwise look right and compare
    /// wrong (§9.5).
    private static let layoutFillers: Set<unichar> = [0x2060, 0x200B, 0xFEFF]

    /// The selection as another application should receive it.
    ///
    /// Kept separate from `attributedStringForRichTextCopy`, which speech still
    /// needs verbatim: `speechProjection` maps spoken ranges back through
    /// TextKit offsets, and that arithmetic only holds while the fillers are
    /// still standing.
    public func exportableAttributedString(range: NSRange) -> NSAttributedString {
        let out = NSMutableAttributedString(
            attributedString: attributedStringForRichTextCopy(range: range)
        )
        let text = out.string as NSString
        var fillerRuns: [NSRange] = []
        var runStart: Int?
        for index in 0..<text.length {
            if Self.layoutFillers.contains(text.character(at: index)) {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                fillerRuns.append(NSRange(location: start, length: index - start))
                runStart = nil
            }
        }
        if let start = runStart {
            fillerRuns.append(NSRange(location: start, length: text.length - start))
        }
        // Back to front, so each deletion leaves the earlier ranges valid.
        for run in fillerRuns.reversed() { out.deleteCharacters(in: run) }
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
        speechProjection(sourceRange: sourceRange).text
    }

    /// Convert a range reported by `NSSpeechSynthesizer` back to source space.
    public func sourceRangeForSpeechRange(_ renderedRange: NSRange, within sourceRange: NSRange) -> NSRange? {
        guard renderedRange.location >= 0, renderedRange.length >= 0 else { return nil }
        let projection = speechProjection(sourceRange: sourceRange)
        guard renderedRange.upperBound <= projection.speechToTextKit.count else { return nil }
        let base = currentDisplayMap.textKitOffset(forSource: sourceRange.location)
        let textKitStart: Int
        let textKitEnd: Int
        if renderedRange.length == 0 {
            textKitStart = renderedRange.location < projection.speechToTextKit.count
                ? projection.speechToTextKit[renderedRange.location]
                : (projection.speechToTextKit.last.map { $0 + 1 } ?? 0)
            textKitEnd = textKitStart
        } else {
            textKitStart = projection.speechToTextKit[renderedRange.location]
            textKitEnd = projection.speechToTextKit[renderedRange.upperBound - 1] + 1
        }
        let textKitRange = NSRange(location: base + textKitStart, length: textKitEnd - textKitStart)
        let mapped = currentDisplayMap.sourceRange(forTextKit: textKitRange)
        guard mapped.location >= sourceRange.location, mapped.upperBound <= sourceRange.upperBound else { return nil }
        return mapped
    }

    /// Drop DisplayMap geometry fillers from speech text while remembering how
    /// each spoken UTF-16 unit maps back into the rich-text (TextKit) string.
    private func speechProjection(sourceRange: NSRange) -> (text: String, speechToTextKit: [Int]) {
        let attributed = attributedStringForRichTextCopy(range: sourceRange)
        let ns = attributed.string as NSString
        var scalars: [UniChar] = []
        var map: [Int] = []
        scalars.reserveCapacity(ns.length)
        map.reserveCapacity(ns.length)
        for index in 0..<ns.length {
            let unit = ns.character(at: index)
            if unit == 0x2060 || unit == 0x200B || unit == 0xFEFF { continue }
            scalars.append(unit)
            map.append(index)
        }
        return (String(utf16CodeUnits: scalars, count: scalars.count), map)
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
