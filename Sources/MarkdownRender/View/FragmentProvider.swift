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
        let plain = { NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange) }
        guard let manager = textElement.textContentManager, let elementRange = textElement.elementRange else {
            return plain()
        }
        let start = manager.offset(from: manager.documentRange.location, to: elementRange.location)
        let end = manager.offset(from: manager.documentRange.location, to: elementRange.endLocation)
        let source = NSRange(location: start, length: max(0, end - start))

        // Elision wins over everything: a folded or zoomed-away paragraph has
        // no height whatever it contains (§5.2, §7.1).
        if context.elision.isElided(source.location) {
            return ElidedFragment(textElement: textElement, range: elementRange)
        }

        guard let storage = context.storage, source.location < storage.length,
              let payload = storage.attribute(.drFragment, at: source.location, effectiveRange: nil) as? FragmentPayload
        else { return plain() }

        // Source mode never renders objects — that is the whole point of it.
        guard context.mode != .source else { return plain() }
        // §6.2: in Live mode the caret entering an object swaps it to source.
        let editing = context.mode == .live && context.isCaretInside(payload.sourceRange)

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

        let isFence = storage.attribute(.drMarker, at: source.location, effectiveRange: nil) != nil
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
}
