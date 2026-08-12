import AppKit
import MarkdownCore

/// §6.1a — the reason Live mode does not jump.
///
/// The source-marker lane is gone. This rail now owns only state that earns a
/// pointer action: change bars, Source-mode line numbers, and the contextual
/// H1...H6 control. The chip hangs outside the text column, so its arrival can
/// never move the heading.
///
/// The rail is a plain `NSView` positioned from the layout manager's fragment
/// geometry, not a text container of its own; there is exactly one layout in
/// this app and the rail reads it.
public final class GutterRailView: NSView {
    weak var textView: MarkdownTextView?

    private var markers: [(offset: Int, text: String, level: Int)] = []
    private var changeBars: [(kind: ChangeKind, range: NSRange)] = []
    private var lineStarts: [Int] = [0]
    private var headingMenuAction: HeadingMenuAction?
    private var trackingArea: NSTrackingArea?

    /// Gap between the rail's right edge — which is the text column's left edge
    /// — and the shared right edge everything in the rail hangs from.  Named
    /// because the block markers and the source-mode line numbers both use it:
    /// two literals drifted apart is a rail whose alignment moves when the mode
    /// does.
    private static let markerInset: CGFloat = 8

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
        setAccessibilityLabel("Document margin")
        setAccessibilityHelp("Heading level and change controls")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Choose current heading level") { [weak self] in
                guard let self, let textView = self.textView else { return false }
                let offset = textView.primarySourceCaret ?? textView.topVisibleOffset
                let index = textView.hoveredHeadingIndex
                    ?? textView.parsedDocument.headings.lastIndex { $0.range.location <= offset }
                guard let index, index < textView.parsedDocument.headings.count else { return false }
                return self.presentHeadingMenu(for: index)
            },
            NSAccessibilityCustomAction(name: "Toggle current section fold") { [weak self] in
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
        updateTrackingAreas()
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

        let visible = convert(textView.visibleRect, from: textView)

        if textView.mode == .source {
            drawLineNumbers(style: style, textView: textView, visible: visible)
        }

        // §8.1: changed blocks get a coloured bar in the margin.
        let changeBarHeight = style.lineHeight
        for bar in changeBars {
            guard let rect = blockRect(for: bar.range, in: textView), rect.intersects(visible) else { continue }
            let color = style.changeColor(bar.kind)
            let height = max(changeBarHeight, rect.height)
            switch bar.kind {
            case .inserted:
                NSBezierPath(
                    roundedRect: NSRect(x: bounds.maxX - 5, y: rect.minY, width: 2.5, height: height),
                    xRadius: 1.25,
                    yRadius: 1.25
                ).fill(with: color)
            case .modified:
                color.setStroke()
                let path = NSBezierPath()
                path.lineWidth = 2
                path.setLineDash([3, 2], count: 2, phase: 0)
                path.move(to: NSPoint(x: bounds.maxX - 3.5, y: rect.minY))
                path.line(to: NSPoint(x: bounds.maxX - 3.5, y: rect.minY + height))
                path.stroke()
            case .deleted:
                let wedge = NSBezierPath()
                wedge.move(to: NSPoint(x: bounds.maxX - 7, y: rect.minY))
                wedge.line(to: NSPoint(x: bounds.maxX - 2, y: rect.minY + 4))
                wedge.line(to: NSPoint(x: bounds.maxX - 7, y: rect.minY + 8))
                wedge.close()
                color.setFill()
                wedge.fill()
            }
        }

        guard textView.mode != .source else { return }

        let activeIndex = activeHeadingIndex
        guard let index = textView.hoveredHeadingIndex ?? activeIndex,
              textView.parsedDocument.headings.indices.contains(index)
        else { return }
        let heading = textView.parsedDocument.headings[index]
        guard let rect = rowRect(for: heading.range, in: textView), rect.intersects(visible) else { return }

        let chip = headingChipRect(for: index, row: rect, in: textView)
        let title = headingChipTitle(for: heading, highlighted: textView.hoveredHeadingIndex == index)
        style.inlineCodeBackground.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
        let size = title.size()
        title.draw(at: NSPoint(x: chip.minX + 5, y: chip.minY + (chip.height - size.height) / 2))

    }

    /// Lazily resolved active block; computed once per draw pass so the
    /// marker loop does not walk the AST for every marker.
    private var activeBlock: MDBlock? {
        guard let textView else { return nil }
        let caret = textView.primarySourceCaret
        return caret.flatMap { textView.parsedDocument.root.block(at: $0) }
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
        // One entry back, because a marker sits at its block's *start* while the
        // bound above is the offset the viewport's top edge lands on — inside
        // that same block.  Searching from it dropped the topmost marker on
        // screen every time, which at the top of a file is the document's `#`.
        let start = max(0, lower - 1)

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
        let origin = textView.textContainerOrigin
        // A hit test above the container's vertical inset resolves to the *end*
        // of the document, not to the first line.  The draw-ahead band starts
        // 40pt above the viewport, so at the top of a file both probes landed in
        // that empty strip, the slice below began past every marker, and the
        // rail drew nothing at all until the reader scrolled 76pt.  Sample
        // inside the laid-out text — the clamp `topVisibleOffset` already makes.
        let top = max(sourceVisible.minY, origin.y) + 1
        let start = textView.sourceOffset(at: NSPoint(x: origin.x, y: top))
        let end = textView.sourceOffset(at: NSPoint(x: origin.x, y: max(top, sourceVisible.maxY)))
        guard (0...storage.length).contains(start),
              (0...storage.length).contains(end) else { return nil }
        let lower = min(start, end)
        let upper = max(start, end)
        return NSRange(location: lower, length: upper - lower)
    }

    private func drawLineNumbers(style: StyleSheet, textView: MarkdownTextView, visible: NSRect) {
        let top = textView.topVisibleOffset
        let first = max(0, (lineStarts.lastIndex { $0 <= top } ?? 0) - 2)
        let font = style.monoFont(size: max(11, style.bodyFont().pointSize * 0.58))
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
                x: max(2, bounds.width - Self.markerInset - size.width),
                y: rect.minY + max(0, (style.lineHeight - size.height) / 2)
            ))

            // Wrapped source lines keep one logical number. Mark every visual
            // continuation so it cannot be mistaken for an unnumbered blank
            // line. The next logical line's origin gives the exact wrapped
            // height without duplicating TextKit's line-breaking policy.
            let nextY: CGFloat? = {
                guard index + 1 < lineStarts.count else { return nil }
                return rowRect(
                    for: NSRange(location: lineStarts[index + 1], length: 0),
                    in: textView
                )?.minY
            }()
            guard let nextY else { continue }
            var continuationY = rect.minY + style.lineHeight
            let continuation = NSAttributedString(string: "↳", attributes: [
                .font: font,
                .foregroundColor: color,
            ])
            let continuationSize = continuation.size()
            while continuationY + style.lineHeight * 0.5 < nextY {
                continuation.draw(at: NSPoint(
                    x: max(2, bounds.width - Self.markerInset - continuationSize.width),
                    y: continuationY + max(0, (style.lineHeight - continuationSize.height) / 2)
                ))
                continuationY += style.lineHeight
            }
        }
    }

    private var activeHeadingIndex: Int? {
        guard let textView, let caret = textView.primarySourceCaret else { return nil }
        return textView.parsedDocument.headings.firstIndex { $0.range.contains(offset: caret) }
    }

    private func rowRect(for range: NSRange, in textView: MarkdownTextView) -> NSRect? {
        guard let rect = textView.rect(forOffset: range.location) else { return nil }
        let converted = convert(rect, from: textView)
        return NSRect(x: 0, y: converted.minY, width: bounds.width, height: max(converted.height, 1))
    }

    private func headingChipTitle(
        for heading: HeadingNode,
        highlighted: Bool
    ) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        let color = highlighted ? (textView?.styleSheet.accent ?? .controlAccentColor) : (textView?.styleSheet.textFaint ?? .secondaryLabelColor)
        return NSAttributedString(string: "H\(heading.level)", attributes: [
            .font: font,
            .foregroundColor: color,
        ])
    }

    private func headingChipRect(
        for index: Int,
        row: NSRect,
        in textView: MarkdownTextView
    ) -> NSRect {
        let heading = textView.parsedDocument.headings[index]
        let title = headingChipTitle(for: heading, highlighted: false)
        let size = title.size()
        return NSRect(
            x: bounds.maxX - Self.markerInset - size.width - 10,
            y: row.minY + max(0, (textView.styleSheet.lineHeight - 18) / 2),
            width: size.width + 10,
            height: 18
        )
    }

    /// Return only the heading whose visible chip contains `point`.
    ///
    /// The old fallback to the active caret heading made a click in empty rail
    /// space mutate whichever heading happened to own the caret.  Besides
    /// being surprising, this became dangerous after a parse moved heading
    /// indices.  Geometry is the source of truth: if a chip is not visible at
    /// the pointer, no heading action is offered.
    func headingIndex(at point: NSPoint) -> Int? {
        guard let textView, textView.mode != .source else { return nil }
        guard let index = textView.hoveredHeadingIndex ?? activeHeadingIndex,
              textView.parsedDocument.headings.indices.contains(index),
              let row = rowRect(
                for: textView.parsedDocument.headings[index].range,
                in: textView
              )
        else { return nil }
        let chip = headingChipRect(for: index, row: row, in: textView)
        return chip.intersects(bounds) && chip.contains(point) ? index : nil
    }

    // MARK: - Pointer handoff

    public override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect,
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    public override func mouseEntered(with event: NSEvent) {
        updateHeadingHover(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseMoved(with event: NSEvent) {
        updateHeadingHover(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) {
        guard let textView, textView.hoveredHeadingIndex != nil else { return }
        textView.hoveredHeadingIndex = nil
        needsDisplay = true
    }

    private func updateHeadingHover(at point: NSPoint) {
        guard let textView else { return }
        let index = headingIndex(at: point)
        guard textView.hoveredHeadingIndex != index else { return }
        textView.hoveredHeadingIndex = index
        needsDisplay = true
        textView.needsDisplay = true
    }

    /// The full vertical span of `range`: the first line's top to the last
    /// line's bottom.
    ///
    /// `rowRect` answers "which row is this offset on", which is the question a
    /// line number and a heading chip ask.  A change *bar* asks a different one.
    /// §8.1 says changed blocks get a coloured bar in the margin, and measuring
    /// it with `rowRect` made it one line tall however much had changed — a stub
    /// that marked where a rewritten section *began* and said nothing about how
    /// far it ran, which is the one thing a margin bar exists to say.
    private func blockRect(for range: NSRange, in textView: MarkdownTextView) -> NSRect? {
        guard let start = textView.rect(forOffset: range.location) else { return nil }
        let last = textView.rect(forOffset: max(range.location, range.upperBound - 1)) ?? start
        let top = convert(start, from: textView)
        let bottom = convert(last, from: textView)
        let minY = min(top.minY, bottom.minY)
        let maxY = max(top.maxY, bottom.maxY)
        return NSRect(x: 0, y: minY, width: bounds.width, height: max(1, maxY - minY))
    }

    // MARK: - Clicking (§7.1)

    public override func mouseDown(with event: NSEvent) {
        guard let textView else { return }
        let point = convert(event.locationInWindow, from: nil)
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        guard modifiers.isEmpty,
              let index = headingIndex(at: point),
              textView.parsedDocument.headings.indices.contains(index),
              let rect = rowRect(for: textView.parsedDocument.headings[index].range, in: textView),
              headingChipRect(for: index, row: rect, in: textView).contains(point)
        else { return }
        _ = presentHeadingMenu(for: index, at: point)
    }

    @discardableResult
    private func presentHeadingMenu(for index: Int, at requestedPoint: NSPoint? = nil) -> Bool {
        guard let textView,
              textView.parsedDocument.headings.indices.contains(index)
        else { return false }
        let action = HeadingMenuAction { [weak textView] level in
            guard let textView else { return }
            textView.markdownDelegate?.markdownTextView(
                textView, didRequestHeadingLevel: level, headingIndex: index
            )
        }
        headingMenuAction = action
        let menu = NSMenu(title: "Heading Level")
        for level in 1...6 {
            let item = NSMenuItem(title: "Heading \(level)", action: #selector(HeadingMenuAction.choose(_:)), keyEquivalent: "")
            item.target = action
            item.tag = level
            item.state = level == textView.parsedDocument.headings[index].level ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let body = NSMenuItem(title: "Body Text", action: #selector(HeadingMenuAction.chooseBody(_:)), keyEquivalent: "")
        body.target = action
        menu.addItem(body)
        let point: NSPoint
        if let requestedPoint {
            point = requestedPoint
        } else if let row = rowRect(for: textView.parsedDocument.headings[index].range, in: textView) {
            let chip = headingChipRect(for: index, row: row, in: textView)
            point = NSPoint(
                x: chip.midX,
                y: min(max(bounds.minY + 8, chip.maxY), bounds.maxY - 8)
            )
        } else {
            point = NSPoint(x: bounds.midX, y: bounds.midY)
        }
        menu.popUp(positioning: nil, at: point, in: self)
        return true
    }
}

private final class HeadingMenuAction: NSObject {
    private let handler: (Int?) -> Void
    init(_ handler: @escaping (Int?) -> Void) { self.handler = handler }
    @objc func choose(_ sender: NSMenuItem) { handler(sender.tag) }
    @objc func chooseBody(_ sender: NSMenuItem) { handler(nil) }
}

private extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}
