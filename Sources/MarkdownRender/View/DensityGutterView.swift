import AppKit
import MarkdownCore

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
            needsDisplay = true
        }
    }

    public var bands: [DensityBand] = [] { didSet { needsDisplay = true } }

    public var outlineEntries: [DensityOutlineEntry] = [] {
        didSet { outline.entries = outlineEntries }
    }

    /// Visible viewport, drawn as the thumb.
    public var visibleRange: ClosedRange<CGFloat> = 0...1 { didSet { needsDisplay = true } }

    /// How far the reader has got, shaded behind everything (§5.1).
    public var readProgress: CGFloat = 0 {
        didSet {
            setAccessibilityValueDescription("\(Int((readProgress * 100).rounded())) percent read")
            needsDisplay = true
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
    /// Rail width.  Lives here rather than in the app's panel metrics so the
    /// Quick Look extension gets the same rail without importing the app.
    public static let width: CGFloat = 28

    public static let minimumHostWidth: CGFloat = 360

    private let preview: DensityGutterPreviewWindow
    private let outline: DensityOutlineWindow
    private var isScrubbing = false
    private var trackingArea: NSTrackingArea?
    private var outlineShowWorkItem: DispatchWorkItem?
    private var outlineHideWorkItem: DispatchWorkItem?

    private let horizontalMargin: CGFloat = 1

    // MARK: - Init

    /// Hosts build panels before they have a theme in hand and assign
    /// `styleSheet` immediately afterwards.
    public convenience init() { self.init(styleSheet: .current) }

    public init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        self.preview = DensityGutterPreviewWindow(styleSheet: styleSheet)
        self.outline = DensityOutlineWindow(styleSheet: styleSheet)
        super.init(frame: NSRect(x: 0, y: 0, width: DensityGutterView.width, height: 100))

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
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Fractions run top-to-bottom through the document, so the view does too.
    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: DensityGutterView.width, height: NSView.noIntrinsicMetric)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let height = bounds.height
        guard height > 0 else { return }
        let contrast = styleSheet.increaseContrast

        drawProgress(height: height, contrast: contrast)
        drawThumb(height: height, contrast: contrast)
        let currentHeading = currentHeadingFraction()

        for band in bands.sorted(by: { Self.paintOrder($0.kind) < Self.paintOrder($1.kind) })
            where Self.isVisibleAtRest(band.kind) {
            draw(band: band, height: height, contrast: contrast, currentHeading: currentHeading)
        }
    }

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

    private func drawProgress(height: CGFloat, contrast: Bool) {
        let progress = min(1, max(0, readProgress))
        guard progress > 0 else { return }
        styleSheet.text.panelAlpha(0.025, increaseContrast: contrast).setFill()
        NSBezierPath(
            rect: NSRect(x: 0, y: 0, width: bounds.width, height: progress * height)
        ).fill()
    }

    private func drawThumb(height: CGFloat, contrast: Bool) {
        let lower = min(max(0, visibleRange.lowerBound), 1)
        let upper = min(max(lower, visibleRange.upperBound), 1)
        let rect = NSRect(
            x: horizontalMargin / 2, y: lower * height,
            width: bounds.width - horizontalMargin,
            height: max(18, (upper - lower) * height)
        )
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        styleSheet.text.panelAlpha(0.09, increaseContrast: contrast).setFill()
        path.fill()
        guard contrast else { return }
        styleSheet.rule.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func draw(
        band: DensityBand,
        height: CGFloat,
        contrast: Bool,
        currentHeading: CGFloat?
    ) {
        let isHeading: Bool
        if case .heading = band.kind { isHeading = true } else { isHeading = false }
        guard isHeading || Self.paintOrder(band.kind) >= 2 else { return }
        var style = self.style(for: band.kind, contrast: contrast)
        if case .heading = band.kind {
            let current = currentHeading == band.startFraction
            style.minHeight = current ? 2 : 1.5
            style.color = current
                ? styleSheet.railTickCurrent.withAlphaComponent(0.9)
                : styleSheet.railTick.withAlphaComponent(band.startFraction <= readProgress ? 0.5 : 0.3)
        }
        let available = bounds.width - horizontalMargin * 2
        let x = horizontalMargin + available * style.inset
        let width = max(2, available * style.width)
        let top = min(max(0, band.startFraction), 1) * height
        let bottom = min(max(0, band.endFraction), 1) * height
        let rect = NSRect(x: x, y: top, width: width, height: max(style.minHeight, bottom - top))

        style.color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
    }

    private struct BandStyle {
        var inset: CGFloat      // fraction of the track from the leading edge
        var width: CGFloat      // fraction of the track
        var minHeight: CGFloat
        var color: NSColor
    }

    private func style(for kind: DensityBand.Kind, contrast: Bool) -> BandStyle {
        switch kind {
        case .heading(let level):
            let lengths: [CGFloat] = [26, 20, 14]
            let width = lengths[min(2, max(0, level - 1))]
            return BandStyle(
                inset: max(0, (bounds.width - width) / max(1, bounds.width)),
                width: width / max(1, bounds.width - horizontalMargin * 2),
                minHeight: 1.5,
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
            return BandStyle(inset: 0, width: 1, minHeight: 2, color: styleSheet.searchHit)
        case .change(let changeKind):
            return BandStyle(inset: 0, width: 1, minHeight: 3, color: styleSheet.changeColor(changeKind))
        }
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
        case .heading, .taskList, .searchHit, .change:
            return true
        case .codeBlock, .table, .math, .image, .callout:
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
        return min(1, max(0, point.y / bounds.height))
    }

    public override func mouseDown(with event: NSEvent) {
        isScrubbing = true
        scrub(to: event, showsSnippet: true)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isScrubbing else { return }
        scrub(to: event, showsSnippet: true)
    }

    public override func mouseUp(with event: NSEvent) {
        isScrubbing = false
        // Stay open if the pointer is still over the rail: the reader is
        // probably about to scrub again.
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside {
            showPreview(at: convert(event.locationInWindow, from: nil), showsSnippet: false)
        } else {
            preview.hide()
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        guard !isScrubbing else { return }
        showPreview(at: convert(event.locationInWindow, from: nil), showsSnippet: false)
        cancelOutlineHide()
        scheduleOutlineShow()
    }

    public override func mouseEntered(with event: NSEvent) {
        cancelOutlineHide()
        scheduleOutlineShow()
    }

    public override func mouseExited(with event: NSEvent) {
        guard !isScrubbing else { return }
        preview.hide()
        scheduleOutlineHide()
    }

    public func presentOutlineForKeyboard() {
        outlineShowWorkItem?.cancel()
        guard let window else { return }
        preview.hide()
        outline.entries = outlineEntries
        outline.show(leftOf: self, over: window, keyboard: true)
    }

    private func scheduleOutlineShow() {
        guard !outline.isVisible, !outlineEntries.isEmpty else { return }
        outlineShowWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window else { return }
            self.preview.hide()
            self.outline.entries = self.outlineEntries
            self.outline.show(leftOf: self, over: window, keyboard: false)
        }
        outlineShowWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DensityOutlineWindow.showDwell, execute: work)
    }

    private func scheduleOutlineHide() {
        outlineShowWorkItem?.cancel()
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
        delegate?.densityGutter(self, didRequestScrollToFraction: fraction(at: point))
        showPreview(at: point, showsSnippet: showsSnippet)
    }

    private func showPreview(at point: NSPoint, showsSnippet: Bool) {
        guard let window, let content = delegate?.densityGutter(self, previewAtFraction: fraction(at: point)) else {
            preview.hide()
            return
        }
        let anchor = window.convertPoint(toScreen: convert(NSPoint(x: 0, y: point.y), to: nil))
        preview.show(
            title: content.title,
            snippet: showsSnippet ? content.snippet : "",
            footer: metricsSummary,
            leftOf: anchor,
            over: window,
            reduceMotion: styleSheet.reduceMotion
        )
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { preview.hide(); outline.dismiss() }
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
