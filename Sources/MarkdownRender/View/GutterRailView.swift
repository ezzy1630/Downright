import AppKit
import MarkdownCore

/// §6.1a — the reason Live mode does not jump.
///
/// `#`, `##`, `>`, `-`, `1.`, `- [ ]` are **never inline**.  They live here, in
/// a narrow left rail: dimmed when inactive, full strength when the caret is in
/// that block.  Because the block's text never gains or loses a leading marker,
/// its horizontal origin and its line height are identical whether or not the
/// caret is in it — which removes every source of vertical jump, the part that
/// actually hurts.
///
/// The rail is a plain `NSView` positioned from the layout manager's fragment
/// geometry, not a text container of its own; there is exactly one layout in
/// this app and the rail reads it.
public final class GutterRailView: NSView {
    weak var textView: MarkdownTextView?

    private var markers: [(offset: Int, text: String, level: Int)] = []
    private var changeBars: [(kind: ChangeKind, range: NSRange)] = []
    private var lineStarts: [Int] = [0]

    public override var isFlipped: Bool { true }

    public init(textView: MarkdownTextView) {
        self.textView = textView
        super.init(frame: .zero)
        // `clipsToBounds` defaults to *false* from macOS 14, and AppKit hands
        // `draw(_:)` a dirty rect that can be larger than the view during a
        // parent's `cacheDisplay(in:to:)`.  A rail that fills its dirty rect
        // unclipped therefore paints the page background over the entire
        // document — offscreen export, PDF, and the Quick Look thumbnail all
        // come out blank.  Clip, and fill `bounds`, never `dirtyRect`.
        clipsToBounds = true
        textView.gutterRail = self
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Markdown gutter")
        setAccessibilityHelp("Block markers and heading navigation")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Toggle current heading") { [weak self] in
                guard let self, let textView = self.textView else { return false }
                let offset = textView.primarySourceCaret ?? textView.topVisibleOffset
                let index = textView.hoveredHeadingIndex
                    ?? textView.parsedDocument.headings.lastIndex { $0.range.location <= offset }
                guard let index, index < textView.parsedDocument.headings.count else { return false }
                textView.markdownDelegate?.markdownTextView(
                    textView,
                    didActivateHeadingAnchor: index,
                    modifiers: [.option]
                )
                return true
            },
        ])
    }

    public required init?(coder: NSCoder) { nil }

    /// Recomputed when the document changes; positions are resolved per draw
    /// because scrolling moves them and nothing else does.
    public func reload() {
        guard let textView else { return }
        markers = textView.engine.gutterMarkers(document: textView.parsedDocument)
        changeBars = textView.changeMarks.map { ($0.kind, $0.range) }
        lineStarts = [0]
        let source = textView.textStorage?.string as NSString? ?? "" as NSString
        var cursor = 0
        while cursor < source.length {
            let range = source.lineRange(for: NSRange(location: cursor, length: 0))
            guard range.upperBound > cursor else { break }
            cursor = range.upperBound
            if cursor < source.length { lineStarts.append(cursor) }
        }
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let textView else { return }
        let style = textView.styleSheet
        style.background.setFill()
        dirtyRect.intersection(bounds).fill()

        let caret = textView.primarySourceCaret
        let activeBlock = caret.flatMap { textView.parsedDocument.root.block(at: $0) }
        let visible = convert(textView.visibleRect, from: textView)

        if textView.mode == .source {
            drawLineNumbers(style: style, textView: textView, visible: visible)
        }

        // §8.1: changed blocks get a coloured bar in the margin.
        for bar in changeBars {
            guard let rect = rowRect(for: bar.range, in: textView), rect.intersects(visible) else { continue }
            let color = style.changeColor(bar.kind)
            NSBezierPath(roundedRect: NSRect(x: bounds.maxX - 5, y: rect.minY, width: 2.5, height: rect.height),
                         xRadius: 1.25, yRadius: 1.25).fill(with: color)
        }

        guard textView.mode.policy.showsGutterMarkers || hoveredHeadingIsVisible else { return }

        let font = style.monoFont(size: max(9, style.bodyFont().pointSize * 0.62))
        for marker in visibleMarkerSlice(in: textView) {
            if let focus = textView.sourceFocus.range,
               focus.contains(offset: marker.offset) { continue }
            guard let rect = rowRect(for: NSRange(location: marker.offset, length: 1), in: textView),
                  rect.intersects(visible.insetBy(dx: 0, dy: -40)) else { continue }
            let isActive = activeBlock.map { $0.range.contains(offset: marker.offset) } ?? false
            let color = isActive ? style.marker.blended(withFraction: 0.5, of: style.text) ?? style.marker
                                 : style.marker
            let attributed = NSAttributedString(string: marker.text, attributes: [
                .font: font,
                .foregroundColor: color,
            ])
            let size = attributed.size()
            // Right-aligned against the text column so deeper nesting reads as
            // a staircase rather than as ragged noise.
            let x = max(2, bounds.width - 8 - size.width)
            attributed.draw(at: NSPoint(x: x, y: rect.minY + max(0, (style.lineHeight - size.height) / 2)))
        }

    }

    private func visibleMarkerSlice(in textView: MarkdownTextView)
        -> ArraySlice<(offset: Int, text: String, level: Int)> {
        guard let visibleSourceRange = visibleSourceRange(in: textView) else {
            return markers[...]
        }

        var lower = 0
        var upper = markers.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if markers[middle].offset < visibleSourceRange.location {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let start = lower

        upper = markers.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if markers[middle].offset <= visibleSourceRange.upperBound {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return markers[start..<lower]
    }

    private func visibleSourceRange(in textView: MarkdownTextView) -> NSRange? {
        guard let storage = textView.textStorage, storage.length > 0 else { return nil }
        let visible = textView.visibleRect
        guard visible.height > 0 else { return nil }

        // Keep the same small draw-ahead band used by the row intersection
        // below, while resolving the viewport in source coordinates once.
        let sourceVisible = visible.insetBy(dx: 0, dy: -40)
        let x = textView.textContainerOrigin.x
        let start = textView.sourceOffset(at: NSPoint(x: x, y: sourceVisible.minY))
        let end = textView.sourceOffset(at: NSPoint(x: x, y: sourceVisible.maxY))
        guard (0...storage.length).contains(start),
              (0...storage.length).contains(end) else { return nil }
        let lower = min(start, end)
        let upper = max(start, end)
        return NSRange(location: lower, length: upper - lower)
    }

    private func drawLineNumbers(style: StyleSheet, textView: MarkdownTextView, visible: NSRect) {
        let top = textView.topVisibleOffset
        let first = max(0, (lineStarts.lastIndex { $0 <= top } ?? 0) - 2)
        let font = style.monoFont(size: max(9, style.bodyFont().pointSize * 0.58))
        let color = style.marker.withAlphaComponent(0.72)
        for index in first..<lineStarts.count {
            guard let rect = rowRect(
                for: NSRange(location: lineStarts[index], length: 0),
                in: textView
            ) else { continue }
            if rect.minY > visible.maxY + 40 { break }
            guard rect.maxY >= visible.minY - 40 else { continue }
            let label = NSAttributedString(string: String(index + 1), attributes: [
                .font: font,
                .foregroundColor: color,
            ])
            let size = label.size()
            label.draw(at: NSPoint(
                x: max(2, bounds.width - 8 - size.width),
                y: rect.minY + max(0, (style.lineHeight - size.height) / 2)
            ))
        }
    }

    private var hoveredHeadingIsVisible: Bool { textView?.hoveredHeadingIndex != nil }

    private func rowRect(for range: NSRange, in textView: MarkdownTextView) -> NSRect? {
        guard let rect = textView.rect(forOffset: range.location) else { return nil }
        let converted = convert(rect, from: textView)
        return NSRect(x: 0, y: converted.minY, width: bounds.width, height: max(converted.height, 1))
    }

    // MARK: - Clicking (§7.1)

    public override func mouseDown(with event: NSEvent) {
        guard let textView else { return }
        let point = convert(event.locationInWindow, from: nil)
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Nearest marker row to the click, so a click anywhere on the row's
        // band counts rather than only on the glyph.  Hit-test only the
        // markers currently in view: a 5k-line document has thousands of
        // headings and most are nowhere near the pointer (§12).
        var best: (offset: Int, distance: CGFloat)?
        for marker in visibleMarkerSlice(in: textView) {
            guard let rect = rowRect(for: NSRange(location: marker.offset, length: 1), in: textView) else { continue }
            guard point.y >= rect.minY - 2, point.y <= rect.maxY + 2 else { continue }
            let distance = abs(rect.midY - point.y)
            if best == nil || distance < best!.distance { best = (marker.offset, distance) }
        }
        guard let hit = best else { return }

        if let index = textView.parsedDocument.headings.firstIndex(where: { $0.range.contains(offset: hit.offset) }) {
            // The controller owns fold state so split views and accessibility
            // actions observe the same mutation.
            textView.activateHeadingAnchor(index, modifiers: modifiers)
            return
        }
        // Clicking any other gutter marker toggles the checkbox it stands for,
        // which is the only fold-free block-level action there is.
        if let task = textView.parsedDocument.tasks.first(where: { $0.contentRange.location >= hit.offset
            && $0.markRange.location >= hit.offset && $0.markRange.location < hit.offset + 8 }) {
            textView.markdownDelegate?.markdownTextView(textView, didToggleCheckboxAtMarkOffset: task.markRange.location)
        }
    }
}

private extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}
