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
    }

    public required init?(coder: NSCoder) { nil }

    /// Recomputed when the document changes; positions are resolved per draw
    /// because scrolling moves them and nothing else does.
    public func reload() {
        guard let textView else { return }
        markers = textView.engine.gutterMarkers(document: textView.parsedDocument)
        changeBars = textView.changeMarks.map { ($0.kind, $0.range) }
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

        // §8.1: changed blocks get a coloured bar in the margin.
        for bar in changeBars {
            guard let rect = rowRect(for: bar.range, in: textView), rect.intersects(visible) else { continue }
            let color = style.changeColor(bar.kind)
            NSBezierPath(roundedRect: NSRect(x: bounds.maxX - 5, y: rect.minY, width: 2.5, height: rect.height),
                         xRadius: 1.25, yRadius: 1.25).fill(with: color)
        }

        guard textView.mode.policy.showsGutterMarkers || hoveredHeadingIsVisible else { return }

        let font = style.monoFont(size: max(9, style.bodyFont().pointSize * 0.62))
        for marker in markers {
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

        drawHeadingAnchor(style: style, textView: textView)
    }

    /// §7.1: hovering a heading puts an anchor glyph in the gutter.  Click it
    /// to copy a link to that section, ⌥-click to fold.
    private func drawHeadingAnchor(style: StyleSheet, textView: MarkdownTextView) {
        guard let index = textView.hoveredHeadingIndex,
              index < textView.parsedDocument.headings.count else { return }
        let heading = textView.parsedDocument.headings[index]
        guard let rect = rowRect(for: heading.range, in: textView) else { return }
        let symbol = textView.foldedHeadingSlugs.contains(heading.slug) ? "chevron.right" : "number"
        guard let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)) else { return }
        let box = NSRect(x: max(2, bounds.width - 8 - icon.size.width),
                         y: rect.minY + max(0, (style.lineHeight - icon.size.height) / 2),
                         width: icon.size.width, height: icon.size.height)
        icon.draw(in: box, from: .zero, operation: .sourceOver, fraction: 0.85)
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
        // band counts rather than only on the glyph.
        var best: (offset: Int, distance: CGFloat)?
        for marker in markers {
            guard let rect = rowRect(for: NSRange(location: marker.offset, length: 1), in: textView) else { continue }
            guard point.y >= rect.minY - 2, point.y <= rect.maxY + 2 else { continue }
            let distance = abs(rect.midY - point.y)
            if best == nil || distance < best!.distance { best = (marker.offset, distance) }
        }
        guard let hit = best else { return }

        if let index = textView.parsedDocument.headings.firstIndex(where: { $0.range.contains(offset: hit.offset) }) {
            let heading = textView.parsedDocument.headings[index]
            // Click folds; the app decides what a plain anchor click means.
            if modifiers.contains(.option) || modifiers.isEmpty {
                textView.toggleFold(headingSlug: heading.slug)
            }
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
