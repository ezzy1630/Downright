import AppKit
import MarkdownCore

@MainActor
public protocol DensityGutterDelegate: AnyObject {
    func densityGutter(_ gutter: DensityGutterView, didRequestScrollToFraction fraction: CGFloat)
    /// Return the heading title and rendered preview for the hover/scrub tooltip.
    func densityGutter(_ gutter: DensityGutterView, previewAtFraction fraction: CGFloat) -> (title: String, snippet: String)?
}

public struct DensityBand {
    public enum Kind {
        case heading(level: Int), codeBlock, table, math, taskList
        case change(ChangeKind), searchHit, image, callout
    }

    public var kind: Kind
    /// 0…1 through the document.
    public var startFraction: CGFloat
    public var endFraction: CGFloat

    public init(kind: Kind, startFraction: CGFloat, endFraction: CGFloat) {
        self.kind = kind
        self.startFraction = startFraction
        self.endFraction = endFraction
    }
}

/// Density gutter (§8.6) — the scrollbar's replacement.
///
/// "The whole shape of a 3,000-word document at a glance."  A scrollbar tells
/// you how much is left; this tells you what is left.  Changed regions are the
/// band that matters most (§8.1), so they are drawn last and can never be
/// occluded by a heading tick or a code block that happens to overlap them.
///
/// The band palette is deliberately narrow.  A theme only guarantees *semantic*
/// colours (§11.2), so inventing six hues here would break the moment someone
/// loads a monochrome theme — kinds are separated by width and weight instead,
/// with the tooltip carrying the specifics on hover.
public final class DensityGutterView: NSView {
    public weak var delegate: DensityGutterDelegate?

    public var styleSheet: StyleSheet {
        didSet {
            preview.styleSheet = styleSheet
            outline.styleSheet = styleSheet
            updateMarkLayers(animated: false)
        }
    }

    public var bands: [DensityBand] = [] {
        didSet {
            hoveredBandIndex = nil
            updateMarkLayers(animated: false)
        }
    }

    public var outlineEntries: [DensityOutlineEntry] = [] {
        didSet { outline.entries = outlineEntries }
    }

    /// Visible viewport, used to style the active prompt mark. The mark group
    /// stays centred in the viewport so scrolling never moves the rail itself.
    public var visibleRange: ClosedRange<CGFloat> = 0...1 {
        didSet {
            updateMarkLayers(animated: true)
        }
    }

    /// How far the reader has got, shaded behind everything (§5.1).
    public var readProgress: CGFloat = 0 {
        didSet {
            setAccessibilityValueDescription("\(Int((readProgress * 100).rounded())) percent read")
            updateMarkLayers(animated: false)
        }
    }

    /// Document word count, character count and read time (§9.6).  Shown as a
    /// footer line in the hover tooltip, "rather than as permanent chrome" —
    /// the gutter is where that information lives in this app.
    public var metricsSummary: String = ""

    public var preferredWidth: CGFloat { DensityGutterView.width }

    /// Narrower than this and the rail is noise rather than signal, so hosts
    /// whose width varies — the Quick Look panel especially (§10, "density
    /// gutter shown if the panel is wide enough") — leave it out.
    /// Rail width. Lives here rather than in the app's panel metrics so the
    /// Quick Look extension gets the same rail without importing the app.
    public static let width: CGFloat = 72

    /// A short dwell keeps the preview immediate without flashing while the
    /// pointer crosses the rail.
    public static let hoverDwell: TimeInterval = 0.04

    public static let minimumHostWidth: CGFloat = 360

    private let preview: DensityGutterPreviewWindow
    private let outline: DensityOutlineWindow
    public private(set) var isScrubbing = false
    private var trackingArea: NSTrackingArea?
    private var previewWorkItem: DispatchWorkItem?
    private var outlineHideWorkItem: DispatchWorkItem?
    private var pointerLocation: NSPoint?

    /// The bars sit on a quiet, centred spine. The spine is deliberately
    /// narrower than the hit area so the map feels easy to scrub without
    /// becoming a second scrollbar.
    private let horizontalMargin: CGFloat = 14
    private let trackInset: CGFloat = 24
    private let markGap: CGFloat = 9
    private let hoverHitSlop: CGFloat = 18
    private let headingMarkWidth: CGFloat = 28
    private var markLayers: [CALayer] = []
    private var hoveredBandIndex: Int?
    private var didDrag = false

    // MARK: - Init

    /// Hosts build panels before they have a theme in hand and assign
    /// `styleSheet` immediately afterwards.
    public convenience init() { self.init(styleSheet: .current) }

    public init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        self.preview = DensityGutterPreviewWindow(styleSheet: styleSheet)
        self.outline = DensityOutlineWindow(styleSheet: styleSheet)
        super.init(frame: NSRect(x: 0, y: 0, width: DensityGutterView.width, height: 100))

        wantsLayer = true

        outline.onSelect = { [weak self] fraction in
            guard let self else { return }
            self.delegate?.densityGutter(self, didRequestScrollToFraction: fraction)
        }
        outline.onPointerPresence = { [weak self] isInside in
            if isInside {
                self?.cancelOutlineHide()
                self?.outline.cancelDismissAnimation()
            } else {
                self?.scheduleOutlineHide()
            }
        }

        // Fully custom-drawn with no accessible subviews, so it has to declare
        // itself an element or VoiceOver never sees it (§11.4).
        setAccessibilityElement(true)
        setAccessibilityRole(.scrollBar)
        setAccessibilityLabel("Document map")
        setAccessibilityValueDescription("0 percent read")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Show document outline") { [weak self] in
                guard let self, self.window != nil, !self.outlineEntries.isEmpty else { return false }
                self.presentOutlineForKeyboard()
                return true
            },
        ])
        updateMarkLayers(animated: false)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Fractions run top-to-bottom through the document, so the view does too.
    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: DensityGutterView.width, height: NSView.noIntrinsicMetric)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateMarkLayers(animated: false)
    }

    // MARK: - Drawing

    private func currentHeadingFraction() -> CGFloat? {
        Self.currentHeadingFraction(in: bands, at: visibleRange)
    }

    static func currentHeadingFraction(
        in bands: [DensityBand], at visibleRange: ClosedRange<CGFloat>
    ) -> CGFloat? {
        let headings = bands.filter {
            if case .heading = $0.kind { return true }
            return false
        }
        return headings.last(where: { $0.startFraction <= visibleRange.lowerBound })?.startFraction
            ?? headings.first?.startFraction
    }

    /// Calculate a centered stack for the visible document marks. This is a
    /// prompt index, not a miniature scrollbar: the marks stay easy to scan
    /// while the active heading changes by appearance rather than movement.
    static func centeredBandYPositions(
        height: CGFloat,
        count: Int,
        trackInset: CGFloat = 24,
        markGap: CGFloat = 9
    ) -> [CGFloat] {
        guard count > 0 else { return [] }

        let top = min(trackInset, max(0, height / 2))
        let bottom = max(top, height - trackInset)
        let trackHeight = max(1, bottom - top)
        let gap = min(markGap, trackHeight / CGFloat(max(1, count - 1)))
        let groupHeight = CGFloat(max(0, count - 1)) * gap
        let start = top + max(0, (trackHeight - groupHeight) / 2)

        return (0..<count).map { start + CGFloat($0) * gap }
    }

    private func visualBands(height: CGFloat) -> [(band: DensityBand, y: CGFloat)] {
        let visible = bands
            .filter { Self.isVisibleAtRest($0.kind) }
            .sorted { lhs, rhs in
                if lhs.startFraction != rhs.startFraction {
                    return lhs.startFraction < rhs.startFraction
                }
                return Self.paintOrder(lhs.kind) < Self.paintOrder(rhs.kind)
            }
        guard !visible.isEmpty else { return [] }

        let positions = Self.centeredBandYPositions(
            height: height,
            count: visible.count,
            trackInset: trackInset,
            markGap: markGap
        )
        return visible.enumerated().map { index, band in
            (band: band, y: positions[index])
        }
    }

    private struct BandStyle {
        var inset: CGFloat      // fraction of the track from the leading edge
        var width: CGFloat      // fraction of the track
        var minHeight: CGFloat
        var color: NSColor
    }

    private func style(for kind: DensityBand.Kind, contrast: Bool) -> BandStyle {
        switch kind {
        case .heading:
            // Keep the resting rail geometrically quiet. Heading depth still
            // remains available to the outline preview, while the rail uses
            // one optical language instead of making a random line look
            // selected because it happens to be an H1 or H4.
            let width = min(headingMarkWidth, bounds.width - horizontalMargin * 2)
            return BandStyle(
                inset: max(0, (bounds.width - horizontalMargin * 2 - width)
                    / (2 * max(1, bounds.width - horizontalMargin * 2))),
                width: width / max(1, bounds.width - horizontalMargin * 2),
                minHeight: 2,
                color: styleSheet.railTick
            )
        case .codeBlock:
            return BandStyle(inset: 0.25, width: 0.5, minHeight: 3,
                             color: styleSheet.textSecondary.panelAlpha(0.5, increaseContrast: contrast))
        case .table:
            return BandStyle(inset: 0.25, width: 0.5, minHeight: 3,
                             color: styleSheet.textSecondary.panelAlpha(0.32, increaseContrast: contrast))
        case .math:
            return BandStyle(inset: 0.32, width: 0.36, minHeight: 3,
                             color: styleSheet.accent.panelAlpha(0.42, increaseContrast: contrast))
        case .taskList:
            return BandStyle(inset: 0.32, width: 0.36, minHeight: 3,
                             color: styleSheet.accent.panelAlpha(0.6, increaseContrast: contrast))
        case .image:
            return BandStyle(inset: 0.38, width: 0.24, minHeight: 3,
                             color: styleSheet.textSecondary.panelAlpha(0.62, increaseContrast: contrast))
        case .callout:
            return BandStyle(inset: 0.2, width: 0.6, minHeight: 3,
                             color: styleSheet.accent.panelAlpha(0.28, increaseContrast: contrast))
        case .searchHit:
            return BandStyle(inset: 0.18, width: 0.64, minHeight: 2, color: styleSheet.searchHit)
        case .change(let changeKind):
            return BandStyle(inset: 0.08, width: 0.84, minHeight: 3, color: styleSheet.changeColor(changeKind))
        }
    }

    /// Renders one small layer per visible document mark. Hover changes only
    /// that layer's width, weight, and colour; there is no floating capsule
    /// that can be mistaken for a scrollbar thumb or cover the document.
    private func updateMarkLayers(animated: Bool) {
        guard bounds.height > 0 else { return }
        let entries = visualBands(height: bounds.height)
        let current = currentHeadingFraction()
        let available = max(1, bounds.width - horizontalMargin * 2)

        while markLayers.count < entries.count {
            let mark = CALayer()
            mark.cornerCurve = .continuous
            mark.masksToBounds = true
            layer?.addSublayer(mark)
            markLayers.append(mark)
        }

        for (index, entry) in entries.enumerated() {
            var bandStyle = style(for: entry.band.kind, contrast: styleSheet.increaseContrast)
            let isCurrent: Bool = {
                guard let current else { return false }
                if case .heading = entry.band.kind {
                    return entry.band.startFraction == current
                }
                return false
            }()
            let isHovered = index == hoveredBandIndex

            if isCurrent {
                bandStyle.color = styleSheet.railTickCurrent.withAlphaComponent(0.9)
            } else if case .heading = entry.band.kind {
                bandStyle.minHeight = 2
                bandStyle.color = styleSheet.railTick.withAlphaComponent(
                    entry.band.startFraction <= readProgress ? 0.5 : 0.3
                )
            }

            if isHovered {
                bandStyle.minHeight = max(bandStyle.minHeight, 3)
                bandStyle.color = styleSheet.railTickCurrent.withAlphaComponent(
                    isCurrent ? 0.96 : 0.86
                )
            }

            let baseWidth = max(2, available * bandStyle.width)
            let markWidth = min(available, baseWidth + (isHovered ? 12 : 0))
            let markHeight = max(bandStyle.minHeight, isHovered ? 4 : bandStyle.minHeight)
            // Resolve every mark around the same optical spine. This keeps a
            // hover expansion symmetric instead of making the line appear to
            // slide sideways inside the lane.
            let markCenter = bounds.midX
                + available * (bandStyle.inset + bandStyle.width / 2 - 0.5)
            let markX = markCenter - markWidth / 2
            let frame = CGRect(x: markX, y: entry.y, width: markWidth, height: markHeight)
            let mark = markLayers[index]
            let previousFrame = mark.presentation()?.frame ?? mark.frame
            let previousColor = mark.presentation()?.backgroundColor ?? mark.backgroundColor
            let frameChanged = previousFrame != frame
            let colorChanged = previousColor != bandStyle.color.cgColor

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mark.frame = frame
            mark.backgroundColor = bandStyle.color.cgColor
            mark.isHidden = false
            CATransaction.commit()

            guard animated, !styleSheet.reduceMotion else { continue }
            let timing = CAMediaTimingFunction(name: .easeOut)

            if frameChanged, previousFrame != .zero {
                let position = CABasicAnimation(keyPath: "position")
                position.fromValue = NSValue(
                    point: NSPoint(x: previousFrame.midX, y: previousFrame.midY)
                )
                position.toValue = NSValue(point: mark.position)
                position.duration = Motion.quick
                position.timingFunction = timing
                mark.add(position, forKey: "mark-position")

                let boundsAnimation = CABasicAnimation(keyPath: "bounds")
                boundsAnimation.fromValue = NSValue(rect: previousFrame.offsetBy(dx: -previousFrame.minX, dy: -previousFrame.minY))
                boundsAnimation.toValue = NSValue(rect: mark.bounds)
                boundsAnimation.duration = Motion.quick
                boundsAnimation.timingFunction = timing
                mark.add(boundsAnimation, forKey: "mark-bounds")
            }

            if colorChanged, let previousColor {
                let colorAnimation = CABasicAnimation(keyPath: "backgroundColor")
                colorAnimation.fromValue = previousColor
                colorAnimation.toValue = bandStyle.color.cgColor
                colorAnimation.duration = Motion.quick
                colorAnimation.timingFunction = timing
                mark.add(colorAnimation, forKey: "mark-color")
            }
        }

        for mark in markLayers.dropFirst(entries.count) {
            mark.removeAllAnimations()
            mark.isHidden = true
        }
    }

    public override func layout() {
        super.layout()
        updateMarkLayers(animated: false)
    }


    /// Changes last, search hits just under them: both are transient answers to
    /// "where is the thing I am looking for", and losing one behind a heading
    /// tick would defeat the feature.
    private static func paintOrder(_ kind: DensityBand.Kind) -> Int {
        switch kind {
        case .heading: return 0
        case .codeBlock, .table, .math, .taskList, .image, .callout: return 1
        case .searchHit: return 2
        case .change: return 3
        }
    }

    /// At rest, the rail carries navigation and review signals.  Body-shape
    /// bands stay available to callers for previews, but do not become a
    /// minimap of code, tables, or other large blocks.
    static func isVisibleAtRest(_ kind: DensityBand.Kind) -> Bool {
        switch kind {
        case .heading, .searchHit, .change:
            return true
        case .codeBlock, .table, .math, .taskList, .image, .callout:
            return false
        }
    }

    // MARK: - Pointer (§7.1 "click to jump, drag to scrub")

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func fraction(at point: NSPoint) -> CGFloat {
        guard bounds.height > 0 else { return 0 }
        let entries = visualBands(height: bounds.height)
        if let nearest = entries.min(by: {
            abs($0.y - point.y) < abs($1.y - point.y)
        }), abs(nearest.y - point.y) <= hoverHitSlop {
            return nearest.band.startFraction
        }
        let top = min(trackInset, max(0, bounds.height / 2))
        let bottom = max(top, bounds.height - trackInset)
        return min(1, max(0, (point.y - top) / max(1, bottom - top)))
    }

    private func updateHoveredBand(at point: NSPoint?, animated: Bool) {
        let nextIndex: Int?
        if let point, bounds.height > 0 {
            let entries = visualBands(height: bounds.height)
            nextIndex = entries.enumerated().min(by: {
                abs($0.element.y - point.y) < abs($1.element.y - point.y)
            }).flatMap { nearest in
                abs(nearest.element.y - point.y) <= hoverHitSlop ? nearest.offset : nil
            }
        } else {
            nextIndex = nil
        }

        guard nextIndex != hoveredBandIndex else { return }
        hoveredBandIndex = nextIndex
        updateMarkLayers(animated: animated)
    }

    public override func mouseDown(with event: NSEvent) {
        didDrag = false
        isScrubbing = false
        pointerLocation = convert(event.locationInWindow, from: nil)
        scrub(to: event, showsSnippet: true)
    }

    public override func mouseDragged(with event: NSEvent) {
        didDrag = true
        isScrubbing = true
        pointerLocation = convert(event.locationInWindow, from: nil)
        scrub(to: event, showsSnippet: true)
    }

    public override func mouseUp(with event: NSEvent) {
        let wasDragging = didDrag
        isScrubbing = false
        didDrag = false
        let point = convert(event.locationInWindow, from: nil)
        pointerLocation = point
        delegate?.densityGutter(self, didRequestScrollToFraction: fraction(at: point))
        // Stay open if the pointer is still over the rail: the reader is
        // probably about to scrub again.
        let inside = bounds.contains(point)
        if inside {
            showPreview(at: point, showsSnippet: true)
        } else {
            preview.hide()
            updateHoveredBand(at: nil, animated: true)
        }
        if wasDragging { needsDisplay = true }
    }

    public override func mouseMoved(with event: NSEvent) {
        guard !isScrubbing else { return }
        let point = convert(event.locationInWindow, from: nil)
        pointerLocation = point
        updateHoveredBand(at: point, animated: true)
        if preview.isVisible {
            showPreview(at: point, showsSnippet: true)
        } else {
            schedulePreview(at: point)
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pointerLocation = point
        updateHoveredBand(at: point, animated: false)
        schedulePreview(at: point)
    }

    public override func mouseExited(with event: NSEvent) {
        guard !isScrubbing else { return }
        previewWorkItem?.cancel()
        previewWorkItem = nil
        pointerLocation = nil
        preview.hide()
        updateHoveredBand(at: nil, animated: true)
    }

    public func presentOutlineForKeyboard() {
        guard let window else { return }
        preview.hide()
        outline.entries = outlineEntries
        outline.show(rightOf: self, over: window, keyboard: true)
    }

    private func schedulePreview(at point: NSPoint) {
        previewWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.window != nil else { return }
            guard self.pointerLocation == point else { return }
            guard self.bounds.contains(point), !self.bands.isEmpty else {
                self.preview.hide()
                return
            }
            self.showPreview(at: point, showsSnippet: true)
        }
        previewWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDwell, execute: work)
    }

    private func scheduleOutlineHide() {
        outlineHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.outline.dismiss() }
        outlineHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DensityOutlineWindow.hideDelay, execute: work)
    }

    private func cancelOutlineHide() {
        outlineHideWorkItem?.cancel()
        outlineHideWorkItem = nil
    }

    private func scrub(to event: NSEvent, showsSnippet: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        updateHoveredBand(at: point, animated: true)
        delegate?.densityGutter(self, didRequestScrollToFraction: fraction(at: point))
        showPreview(at: point, showsSnippet: showsSnippet)
    }

    private func showPreview(at point: NSPoint, showsSnippet: Bool) {
        guard let window, let content = delegate?.densityGutter(self, previewAtFraction: fraction(at: point)) else {
            preview.hide()
            return
        }
        let anchor = window.convertPoint(toScreen: convert(NSPoint(x: bounds.width, y: point.y), to: nil))
        preview.show(
            title: content.title,
            snippet: showsSnippet ? content.snippet : "",
            footer: metricsSummary,
            rightOf: anchor,
            over: window,
            reduceMotion: styleSheet.reduceMotion
        )
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            previewWorkItem?.cancel()
            previewWorkItem = nil
            pointerLocation = nil
            preview.hide()
            updateHoveredBand(at: nil, animated: false)
            outline.dismiss()
        }
    }

    // MARK: - Band construction

    /// Builds bands from a parsed document plus overlays.  Static so the Quick
    /// Look extension can reuse it (§10) without instantiating a view.
    public static func bands(
        for document: ParsedDocument,
        changes: [(ChangeKind, NSRange)],
        searchHits: [NSRange]
    ) -> [DensityBand] {
        let length = CGFloat(max(1, document.length))
        func band(_ kind: DensityBand.Kind, _ range: NSRange) -> DensityBand {
            let start = min(1, max(0, CGFloat(range.location) / length))
            let end = min(1, max(start, CGFloat(range.upperBound) / length))
            return DensityBand(kind: kind, startFraction: start, endFraction: end)
        }

        var result: [DensityBand] = []
        document.root.walkPruning { block in
            switch block.content {
            case .heading(let level):
                result.append(band(.heading(level: level), block.range))
                return false
            case .codeBlock:
                result.append(band(.codeBlock, block.range))
                return false
            case .mermaid:
                // A diagram is a figure, not code, once it is rendered (§6.2).
                result.append(band(.image, block.range))
                return false
            case .mathBlock:
                result.append(band(.math, block.range))
                return false
            case .table:
                result.append(band(.table, block.range))
                return false
            case .callout:
                // Pruned: a callout is a single visual object in the rail even
                // when it contains a list, and nesting bands inside bands makes
                // a 14pt track unreadable.
                result.append(band(.callout, block.range))
                return false
            case .list:
                guard containsCheckbox(block) else { return true }
                result.append(band(.taskList, block.range))
                return false
            case .paragraph:
                if containsImage(block) { result.append(band(.image, block.range)) }
                return false
            default:
                return true
            }
        }

        for (kind, range) in changes { result.append(band(.change(kind), range)) }
        for hit in searchHits { result.append(band(.searchHit, hit)) }
        return result
    }

    private static func containsCheckbox(_ block: MDBlock) -> Bool {
        block.children.contains { child in
            if case .listItem(_, let checkbox) = child.content { return checkbox != nil }
            return false
        }
    }

    private static func containsImage(_ block: MDBlock) -> Bool {
        var found = false
        for inline in block.inlines {
            inline.walk { span in
                if case .image = span.kind { found = true }
            }
            if found { break }
        }
        return found
    }
}
