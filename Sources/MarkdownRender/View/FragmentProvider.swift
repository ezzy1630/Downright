import AppKit
import MarkdownCore

/// Chooses the `NSTextLayoutFragment` subclass for every paragraph.
///
/// This is where §6.2's per-element table becomes code: the same block draws
/// as an object in Read mode, as an object in Live mode until the caret enters
/// it, and as plain highlighted source in Source mode — one decision, made in
/// one place, from `RenderMode` and the caret.
final class FragmentProvider: NSObject, NSTextLayoutManagerDelegate {
    let context: FragmentContext

    init(context: FragmentContext) {
        self.context = context
    }

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        // Prose is a drawing fragment too.  Everything that belongs behind or
        // among a paragraph's own glyphs — the inline-code pills, the
        // invisibles — is painted by the pass that draws those glyphs, so it
        // cannot be left behind at a position the layout has since moved on
        // from.
        let plain = {
            ProseFragment(
                textElement: textElement,
                range: textElement.elementRange,
                context: self.context
            )
        }
        guard let manager = textElement.textContentManager, let elementRange = textElement.elementRange else {
            return plain()
        }
        let start = manager.offset(from: manager.documentRange.location, to: elementRange.location)
        let end = manager.offset(from: manager.documentRange.location, to: elementRange.endLocation)
        let source = NSRange(location: start, length: max(0, end - start))

        // Elision wins over everything: a folded or zoomed-away paragraph has
        // no height whatever it contains (§5.2, §7.1).
        if context.elision.isElided(source.location) {
            if let hidden = context.cueElision.range(containing: source.location),
               context.paragraphIndex.index(containing: source.location)
                    == context.paragraphIndex.index(containing: hidden.location) {
                return ElisionCueFragment(
                    textElement: textElement,
                    range: elementRange,
                    hiddenRange: hidden,
                    context: context
                )
            }
            return ElidedFragment(textElement: textElement, range: elementRange)
        }

        guard let storage = context.storage, source.location < storage.length,
              let payload = codePayload(in: storage, paragraph: source)
        else { return plain() }

        // Source mode never renders objects — that is the whole point of it.
        guard context.mode != .source else { return plain() }
        // §6.2: a caret inside an object or an explicit scoped source lens
        // swaps only that object to source.  Surrounding blocks stay rendered.
        let editing = context.mode == .live
            && (context.isCaretInside(payload.sourceRange) || context.isSourceFocused(payload.sourceRange))

        switch payload.kind {
        case .codeBlock, .collapsedCodeBlock:
            return codeFragment(textElement: textElement, elementRange: elementRange,
                                source: source, payload: payload, storage: storage)

        case .table:
            guard !editing else { return plain() }
            // The `|---|:--:|` row is syntax, not data: it collapses rather
            // than leaving a blank band where a row should be.
            if let delimiter = payload.tableData?.delimiterRange, delimiter.contains(offset: source.location) {
                return ElidedFragment(textElement: textElement, range: elementRange)
            }
            return TableRowFragment.make(textElement: textElement, range: elementRange,
                                         payload: payload, context: context) ?? plain()

        case .blockMath:
            guard !editing else { return plain() }
            return MathFragment(textElement: textElement, range: elementRange, payload: payload, context: context)

        case .mermaid:
            guard !editing else { return plain() }
            return MermaidFragment(textElement: textElement, range: elementRange, payload: payload, context: context)

        case .image:
            guard !editing else { return plain() }
            return ImageFragment(textElement: textElement, range: elementRange, payload: payload, context: context)

        case .frontMatter:
            guard !editing, !context.frontMatterFields.isEmpty else { return plain() }
            return FrontMatterFragment(textElement: textElement, range: elementRange, payload: payload,
                                       context: context, fields: context.frontMatterFields)

        case .thematicBreak:
            return ThematicBreakFragment(textElement: textElement, range: elementRange,
                                         payload: payload, context: context)

        case .callout:
            // The rule and the icon stay on while editing: they are chrome
            // around real text, not a replacement for it.
            return CalloutFragment(textElement: textElement, range: elementRange,
                                   payload: payload, context: context)

        case .listOrnament:
            return ListOrnamentFragment(textElement: textElement, range: elementRange,
                                        payload: payload, context: context)

        case .inlineMath:
            return plain()
        }
    }

    // MARK: - Code blocks

    private func codeFragment(
        textElement: NSTextElement,
        elementRange: NSTextRange,
        source: NSRange,
        payload: FragmentPayload,
        storage: NSTextStorage
    ) -> NSTextLayoutFragment {
        let block = payload.sourceRange
        let lines = lineCount(of: block)
        let collapsed = context.collapseOverrides[block.location] ?? (payload.kind == .collapsedCodeBlock)

        if collapsed {
            // §5.1: one line — language, line count, click to expand.
            guard source.location <= block.location else {
                return ElidedFragment(textElement: textElement, range: elementRange)
            }
            return CodeBlockFragment(textElement: textElement, range: elementRange, payload: payload,
                                     context: context, role: .collapsedChip, lineCount: lines)
        }

        // The fence's paragraph starts at the source line's indentation for a
        // nested block — the parser leaves the leading spaces out of the
        // block's range (e.g. 79 vs the line start 77) — so the `.drMarker`
        // sits after the whitespace run, never at the paragraph's start.
        let isFence = paragraphContainsFenceMarker(in: storage, paragraph: source)
        let role: CodeBlockFragment.Role
        if isFence, source.location <= block.location { role = .openChrome }
        else if isFence, source.upperBound >= block.upperBound { role = .closeChrome }
        else { role = .body }

        return CodeBlockFragment(textElement: textElement, range: elementRange, payload: payload,
                                 context: context, role: role, lineCount: lines)
    }

    private func lineCount(of range: NSRange) -> Int {
        let index = context.paragraphIndex
        guard range.length > 0 else { return 0 }
        let first = index.index(containing: range.location)
        let last = index.index(containing: max(range.location, range.upperBound - 1))
        // Minus the two fence lines when they are present; a block that is all
        // fence is reported as empty rather than as -1 lines.
        return max(0, last - first - 1)
    }

    /// The `.drFragment` owning a paragraph.
    ///
    /// The attribute usually sits at the paragraph's start, but the parser
    /// leaves a block's *container indentation* out of its range: a nested
    /// item's range begins at its own marker, not at the line start (e.g. 79 vs
    /// the line start 77).  Every enclosing block — the outer list item, the
    /// blockquote — does span those leading columns, so the character at the
    /// paragraph's start carries the payload of the *outermost* block on the
    /// line rather than the one that actually begins there.
    ///
    /// Reading only that character is what made every nested ornament vanish:
    /// an indented item resolved to its parent's payload, and the fragment then
    /// found `isFirstParagraphOfBlock == false` and drew nothing at all — no
    /// bullet, no number, no checkbox, at any depth past the first.
    ///
    /// So resolve the *innermost* block that begins on this line: step over the
    /// container prefix and take the payload found there when its own range
    /// starts inside this paragraph.  A continuation paragraph (an item's
    /// second paragraph, a fence body) has no block starting on it, keeps the
    /// enclosing payload, and still renders as continuation.
    private func codePayload(in storage: NSTextStorage, paragraph source: NSRange) -> FragmentPayload? {
        let start = storage.attribute(.drFragment, at: source.location, effectiveRange: nil) as? FragmentPayload
        // Code keeps first refusal.  Its probe is deliberately more generous
        // than the container prefix below — a fence may sit behind list and
        // quote markers — and the fence/body role split downstream depends on
        // the code payload winning whenever one is on the line.
        if let start, isCode(start.kind) { return start }
        if let code = codePayloadAfterWhitespace(in: storage, paragraph: source) { return code }
        return innermostPayloadAfterIndent(in: storage, paragraph: source) ?? start
    }

    /// The payload of the innermost block *beginning* on this paragraph, found
    /// by stepping over the container prefix the parser excluded from its range.
    ///
    /// The prefix is whitespace and blockquote markers only — never a list
    /// marker or an ordered-list digit.  Those belong to the item whose payload
    /// is being resolved, and skipping them would walk past the very block this
    /// is meant to find and into whatever nests inside it.
    private func innermostPayloadAfterIndent(
        in storage: NSTextStorage, paragraph source: NSRange
    ) -> FragmentPayload? {
        let probe = containerPrefixEnd(in: storage, paragraph: source)
        guard probe < source.upperBound, probe < storage.length,
              let payload = storage.attribute(.drFragment, at: probe, effectiveRange: nil) as? FragmentPayload,
              // "Begins on this line" is the whole test: it separates a nested
              // item (its range starts at the marker we just stepped up to)
              // from an enclosing block that merely covers these columns.
              payload.sourceRange.location >= source.location,
              payload.sourceRange.location < source.upperBound
        else { return nil }
        return payload
    }

    /// End of the leading *container* prefix: indentation and `>` markers.
    private func containerPrefixEnd(in storage: NSTextStorage, paragraph source: NSRange) -> Int {
        let end = min(source.upperBound, source.location + 256)
        let text = storage.string as NSString
        var probe = source.location
        while probe < end {
            switch text.character(at: probe) {
            case 0x20, 0x09, 0x3E: probe += 1  // space, tab, `>`
            default: return probe
            }
        }
        return probe
    }

    private func codePayloadAfterWhitespace(in storage: NSTextStorage, paragraph source: NSRange) -> FragmentPayload? {
        let probe = firstNonWhitespaceOffset(in: storage, paragraph: source)
        guard probe > source.location, probe < source.upperBound,
              let payload = storage.attribute(.drFragment, at: probe, effectiveRange: nil) as? FragmentPayload,
              isCode(payload.kind)
        else { return nil }
        return payload
    }

    private func isCode(_ kind: FragmentKind) -> Bool {
        switch kind {
        case .codeBlock, .collapsedCodeBlock: return true
        default: return false
        }
    }

    /// True when the paragraph carries a fence marker (`.drMarker`), probing
    /// past the leading whitespace a nested fence inherits from its source
    /// line.  Only fences are marker-attributed inside a code block, so a hit
    /// anywhere on the line means "this line is chrome".
    private func paragraphContainsFenceMarker(in storage: NSTextStorage, paragraph source: NSRange) -> Bool {
        let probe = firstNonWhitespaceOffset(in: storage, paragraph: source)
        guard probe < source.upperBound else { return false }
        return storage.attribute(.drMarker, at: probe, effectiveRange: nil) != nil
    }

    /// First offset past the paragraph's leading *marker prefix*: the source
    /// indentation a nested block inherits, plus any blockquote `>` and list
    /// markers the parser left on the line (`> ````, `- ````, `1. ````).  The
    /// fence's paragraph starts at that prefix, never at the block's range.
    /// Over-skipping is harmless — the callers only accept a *code* payload or
    /// fence marker, and those exist solely at genuine block starts — so the
    /// skip set is deliberately generous.
    private func firstNonWhitespaceOffset(in storage: NSTextStorage, paragraph source: NSRange) -> Int {
        let end = min(source.upperBound, source.location + 256)
        let text = storage.string as NSString
        var probe = source.location
        var lastWasDigit = false
        scan: while probe < end {
            let unit = text.character(at: probe)
            switch unit {
            case 0x20, 0x09, 0x3E, 0x2D, 0x2A, 0x2B: // space, tab, `>`, `-`, `*`, `+`
                lastWasDigit = false
                probe += 1
            case 0x30...0x39: // digit (ordered-list marker)
                lastWasDigit = true
                probe += 1
            case 0x2E where lastWasDigit: // `.` terminating an ordered marker
                lastWasDigit = false
                probe += 1
            default:
                break scan
            }
        }
        return probe
    }
}
