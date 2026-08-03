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

    /// Scrub preview appears almost immediately; outline bloom waits longer.
    public static let hoverDwell: TimeInterval = 0.02
    /// Passive hover may begin before the pointer reaches a mark, but it must
    /// never activate from an arbitrary point in the rail.
    static let hoverActivationSlop: CGFloat = 22
    /// Once a mark owns the hover, leaving its row dismisses chrome.
    static let hoverDismissalSlop: CGFloat = 4
    /// Small bridge only for the physical gap between a mark and its preview.
    static let previewExitDelay: TimeInterval = 0.06
    /// Distance over which mark size / brightness fall off from the pointer.
    static let proximityRadius: CGFloat = 36
    /// Maximum magnetic pull of a mark toward the pointer (points).
    static let magneticPull: CGFloat = 1.5
    /// Maximum fractional compression of the centred stack near the pointer.
    static let stackCompression: CGFloat = 0.08

    public static let minimumHostWidth: CGFloat = 360

    private let preview: DensityGutterPreviewWindow
    private let outline: DensityOutlineWindow
    public private(set) var isScrubbing = false
    private var trackingArea: NSTrackingArea?
    private var previewWorkItem: DispatchWorkItem?
    private var previewHideWorkItem: DispatchWorkItem?
    private var outlineWorkItem: DispatchWorkItem?
    private var outlineHideWorkItem: DispatchWorkItem?
    private var pointerLocation: NSPoint?
    private var pointerIsInPreview = false
    private var pointerIsInOutline = false

    /// The bars sit on a quiet, centred spine. The spine is deliberately
    /// narrower than the hit area so the map feels easy to scrub without
    /// becoming a second scrollbar.
    private let horizontalMargin: CGFloat = 16
    private let trackInset: CGFloat = 28
    private let markGap: CGFloat = 10
    private let spineLayer = CALayer()
    private var markLayers: [CALayer] = []
    private var hoveredBandIndex: Int?
    private var didDrag = false
    private var isEngaged = false

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
        spineLayer.cornerCurve = .continuous
        spineLayer.masksToBounds = true
        spineLayer.opacity = 0
        layer?.addSublayer(spineLayer)

        preview.onPointerPresence = { [weak self] isInside in
            guard let self else { return }
            self.pointerIsInPreview = isInside
            if isInside {
                self.cancelPreviewHide()
                self.preview.cancelHideAnimation()
            } else if !self.isScrubbing {
                self.schedulePreviewHide()
            }
        }

        outline.onSelect = { [weak self] fraction in
            guard let self else { return }
            self.delegate?.densityGutter(self, didRequestScrollToFraction: fraction)
        }
        outline.onPointerPresence = { [weak self] isInside in
            guard let self else { return }
            self.pointerIsInOutline = isInside
            if isInside {
                self.cancelOutlineHide()
                self.outline.cancelDismissAnimation()
            } else if !self.isScrubbing {
                self.scheduleOutlineHide()
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
        trackInset: CGFloat = 28,
        markGap: CGFloat = 10,
        pointerY: CGFloat? = nil,
        compression: CGFloat = DensityGutterView.stackCompression,
        proximityRadius: CGFloat = DensityGutterView.proximityRadius
    ) -> [CGFloat] {
        guard count > 0 else { return [] }

        let top = min(trackInset, max(0, height / 2))
        let bottom = max(top, height - trackInset)
        let trackHeight = max(1, bottom - top)
        let gap = min(markGap, trackHeight / CGFloat(max(1, count - 1)))
        let groupHeight = CGFloat(max(0, count - 1)) * gap
        let start = top + max(0, (trackHeight - groupHeight) / 2)
        let base = (0..<count).map { start + CGFloat($0) * gap }

        guard let pointerY, count > 1, compression > 0 else { return base }

        // Soft Dock-like compression: gaps near the pointer shrink a little so
        // the stack feels magnetic without rearranging reading order.
        var compressed: [CGFloat] = [base[0]]
        for index in 1..<count {
            let mid = (base[index - 1] + base[index]) / 2
            let influence = proximityInfluence(
                distance: abs(mid - pointerY),
                radius: proximityRadius
            )
            let localGap = gap * (1 - compression * influence)
            compressed.append(compressed[index - 1] + localGap)
        }
        let compressedSpan = (compressed.last ?? 0) - compressed[0]
        let recenter = start + max(0, (groupHeight - compressedSpan) / 2) - compressed[0]
        return compressed.map { $0 + recenter }
    }

    /// Ease-out falloff in 0…1 for pointer distance.
    static func proximityInfluence(distance: CGFloat, radius: CGFloat = proximityRadius) -> CGFloat {
        guard radius > 0 else { return distance <= 0 ? 1 : 0 }
        let t = min(1, max(0, 1 - distance / radius))
        return t * t * (3 - 2 * t) // smoothstep
    }

    /// Resting tick length encodes heading level.
    static func headingMarkWidth(level: Int) -> CGFloat {
        switch max(1, level) {
        case 1: return 26
        case 2: return 20
        case 3: return 14
        default: return 10
        }
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
            markGap: markGap,
            pointerY: pointerLocation?.y
        )
        return visible.enumerated().map { index, band in
            (band: band, y: positions[index])
        }
    }

    private struct BandStyle {
        var widthPoints: CGFloat
        var minHeight: CGFloat
        var color: NSColor
    }

    private func style(for kind: DensityBand.Kind, contrast: Bool) -> BandStyle {
        let maxWidth = max(2, bounds.width - horizontalMargin * 2)
        switch kind {
        case .heading(let level):
            return BandStyle(
                widthPoints: min(Self.headingMarkWidth(level: level), maxWidth),
                minHeight: level <= 1 ? 2.5 : 2,
                color: styleSheet.railTick
            )
        case .searchHit:
            return BandStyle(
                widthPoints: min(10, maxWidth),
                minHeight: 2,
                color: styleSheet.searchHit
            )
        case .change(let changeKind):
            return BandStyle(
                widthPoints: min(12, maxWidth),
                minHeight: 2.5,
                color: styleSheet.changeColor(changeKind)
            )
        case .codeBlock, .table, .math, .taskList, .image, .callout:
            // Body-shape bands stay in the data model but are not drawn at rest.
            return BandStyle(
                widthPoints: min(8, maxWidth),
                minHeight: 2,
                color: styleSheet.textSecondary.panelAlpha(0.4, increaseContrast: contrast)
            )
        }
    }

    /// Renders one small layer per visible document mark. Every mark shares the
    /// same optical spine so the rail reads as one centred stick; proximity
    /// only changes length, weight, and brightness.
    private func updateMarkLayers(animated: Bool) {
        guard bounds.height > 0 else { return }
        let entries = visualBands(height: bounds.height)
        let current = currentHeadingFraction()
        let available = max(1, bounds.width - horizontalMargin * 2)
        let pointerY = pointerLocation?.y
        let engaged = pointerLocation != nil || isScrubbing || outline.isVisible
        updateSpine(engaged: engaged)

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
            let distance = pointerY.map { abs(entry.y - $0) }
            let influence = distance.map {
                Self.proximityInfluence(distance: $0, radius: Self.proximityRadius)
            } ?? 0
            let isPrimary = index == hoveredBandIndex
            let focus = isPrimary ? max(influence, 0.78) : influence * 0.72

            if isCurrent {
                bandStyle.color = styleSheet.railTickCurrent.withAlphaComponent(0.92)
                bandStyle.minHeight = max(bandStyle.minHeight, 3)
            } else if case .heading = entry.band.kind {
                bandStyle.color = styleSheet.railTick.withAlphaComponent(
                    entry.band.startFraction <= readProgress ? 0.48 : 0.28
                )
            }

            if focus > 0.02 {
                let alpha = (isCurrent ? 0.92 : 0.52) + focus * (isCurrent ? 0.06 : 0.42)
                bandStyle.color = styleSheet.railTickCurrent.withAlphaComponent(min(0.98, alpha))
            }

            let markWidth = min(available, bandStyle.widthPoints + focus * 12)
            let markHeight = bandStyle.minHeight + focus * 2.2
            let magnetic = (pointerY.map { ($0 - entry.y) } ?? 0)
                * focus * (Self.magneticPull / max(1, Self.proximityRadius))
            let markY = entry.y + max(-Self.magneticPull, min(Self.magneticPull, magnetic))
            // One optical spine: every mark grows symmetrically from midX.
            let markX = bounds.midX - markWidth / 2
            let frame = CGRect(
                x: markX,
                y: markY - markHeight / 2,
                width: markWidth,
                height: markHeight
            )
            let mark = markLayers[index]
            let previousFrame = mark.presentation()?.frame ?? mark.frame
            let previousColor = mark.presentation()?.backgroundColor ?? mark.backgroundColor
            let frameChanged = previousFrame != frame
            let colorChanged = previousColor != bandStyle.color.cgColor

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mark.cornerRadius = min(markHeight / 2, 2)
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
                boundsAnimation.fromValue = NSValue(
                    rect: previousFrame.offsetBy(dx: -previousFrame.minX, dy: -previousFrame.minY)
                )
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

    private func updateSpine(engaged: Bool) {
        let top = min(trackInset, max(0, bounds.height / 2))
        let bottom = max(top, bounds.height - trackInset)
        let width: CGFloat = 1
        let frame = CGRect(
            x: bounds.midX - width / 2,
            y: top,
            width: width,
            height: max(0, bottom - top)
        )
        let targetOpacity: Float = engaged ? 0.14 : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spineLayer.cornerRadius = 0.5
        spineLayer.frame = frame
        spineLayer.backgroundColor = styleSheet.railTick.withAlphaComponent(1).cgColor
        CATransaction.commit()

        guard isEngaged != engaged || abs(spineLayer.opacity - targetOpacity) > 0.001 else { return }
        isEngaged = engaged
        if styleSheet.reduceMotion {
            spineLayer.opacity = targetOpacity
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = spineLayer.presentation()?.opacity ?? spineLayer.opacity
        fade.toValue = targetOpacity
        fade.duration = Motion.quick
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        spineLayer.opacity = targetOpacity
        spineLayer.add(fade, forKey: "spine-opacity")
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
        }), abs(nearest.y - point.y) <= Self.hoverActivationSlop {
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
            nextIndex = Self.nextHoveredBandIndex(
                at: point.y,
                positions: entries.map { $0.y },
                currentIndex: hoveredBandIndex,
                activationSlop: Self.hoverActivationSlop,
                dismissalSlop: Self.hoverDismissalSlop
            )
        } else {
            nextIndex = nil
        }

        let indexChanged = nextIndex != hoveredBandIndex
        hoveredBandIndex = nextIndex
        // Continuous proximity must track the pointer without CA lag; only
        // animate when the primary mark changes (enter / leave / switch).
        if indexChanged || point != nil || pointerLocation != nil {
            updateMarkLayers(animated: animated && indexChanged)
        }
    }

    static func nextHoveredBandIndex(
        at y: CGFloat,
        positions: [CGFloat],
        currentIndex: Int?,
        activationSlop: CGFloat,
        dismissalSlop: CGFloat
    ) -> Int? {
        guard let nearest = positions.indices.min(by: {
            abs(positions[$0] - y) < abs(positions[$1] - y)
        }) else { return nil }

        if let currentIndex,
           positions.indices.contains(currentIndex) {
            let currentDistance = abs(positions[currentIndex] - y)
            if currentDistance <= dismissalSlop { return currentIndex }
            if nearest == currentIndex { return nil }
        }
        return abs(positions[nearest] - y) <= activationSlop ? nearest : nil
    }

    public override func mouseDown(with event: NSEvent) {
        cancelPreviewHide()
        cancelOutlineShow()
        cancelOutlineHide()
        pointerIsInPreview = false
        pointerIsInOutline = false
        outline.dismiss()
        didDrag = false
        isScrubbing = false
        pointerLocation = convert(event.locationInWindow, from: nil)
        scrub(to: event, showsSnippet: true, interactive: false)
    }

    public override func mouseDragged(with event: NSEvent) {
        cancelPreviewHide()
        cancelOutlineShow()
        pointerIsInPreview = false
        pointerIsInOutline = false
        if outline.isVisible { outline.dismiss() }
        didDrag = true
        isScrubbing = true
        pointerLocation = convert(event.locationInWindow, from: nil)
        scrub(to: event, showsSnippet: true, interactive: false)
    }

    public override func mouseUp(with event: NSEvent) {
        let wasDragging = didDrag
        isScrubbing = false
        didDrag = false
        let point = convert(event.locationInWindow, from: nil)
        pointerLocation = point
        updateHoveredBand(at: point, animated: true)
        delegate?.densityGutter(self, didRequestScrollToFraction: fraction(at: point))
        if bounds.contains(point), hoveredBandIndex != nil {
            // A click settles into outline bloom rather than a sticky tooltip.
            preview.hide()
            scheduleOutline(at: point, dwell: 0)
        } else {
            cancelPreviewHide()
            preview.hide()
            cancelOutlineShow()
            outline.dismiss()
            updateHoveredBand(at: nil, animated: true)
            pointerLocation = nil
        }
        if wasDragging { needsDisplay = true }
    }

    public override func mouseMoved(with event: NSEvent) {
        guard !isScrubbing else { return }
        let point = convert(event.locationInWindow, from: nil)
        cancelPreviewHide()
        pointerIsInPreview = false
        pointerLocation = point
        updateHoveredBand(at: point, animated: true)
        guard hoveredBandIndex != nil else {
            previewWorkItem?.cancel()
            previewWorkItem = nil
            cancelOutlineShow()
            preview.hide()
            if !pointerIsInOutline { scheduleOutlineHide() }
            return
        }
        // Deliberate hover → outline bloom. Scrub keeps the lightweight preview.
        preview.hide()
        if outline.isVisible {
            cancelOutlineHide()
        } else {
            scheduleOutline(at: point)
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cancelPreviewHide()
        cancelOutlineHide()
        pointerIsInPreview = false
        pointerLocation = point
        updateHoveredBand(at: point, animated: false)
        if hoveredBandIndex != nil {
            scheduleOutline(at: point)
        }
    }

    public override func mouseExited(with event: NSEvent) {
        guard !isScrubbing else { return }
        previewWorkItem?.cancel()
        previewWorkItem = nil
        cancelOutlineShow()
        pointerLocation = nil
        updateMarkLayers(animated: true)
        guard preview.isVisible || outline.isVisible else {
            updateHoveredBand(at: nil, animated: true)
            return
        }
        if preview.isVisible { schedulePreviewHide() }
        if outline.isVisible, !pointerIsInOutline { scheduleOutlineHide() }
        if !preview.isVisible, !outline.isVisible {
            updateHoveredBand(at: nil, animated: true)
        }
    }

    public func presentOutlineForKeyboard() {
        guard let window else { return }
        cancelPreviewHide()
        cancelOutlineShow()
        pointerIsInPreview = false
        preview.hide()
        outline.entries = outlineEntries
        let anchorY = hoveredBandIndex.flatMap { index in
            let entries = visualBands(height: bounds.height)
            return entries.indices.contains(index) ? entries[index].y : nil
        }
        outline.show(rightOf: self, over: window, keyboard: true, anchorY: anchorY)
    }

    private func schedulePreview(at point: NSPoint) {
        previewWorkItem?.cancel()
        cancelPreviewHide()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.window != nil else { return }
            guard self.pointerLocation == point else { return }
            guard self.bounds.contains(point), !self.bands.isEmpty,
                  self.hoveredBandIndex != nil else {
                self.preview.hide()
                return
            }
            self.showPreview(at: point, showsSnippet: true)
        }
        previewWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDwell, execute: work)
    }

    private func scheduleOutline(at point: NSPoint, dwell: TimeInterval = DensityOutlineWindow.showDwell) {
        outlineWorkItem?.cancel()
        cancelOutlineHide()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window else { return }
            guard self.pointerLocation == point || dwell == 0 else { return }
            guard !self.isScrubbing, self.hoveredBandIndex != nil,
                  !self.outlineEntries.isEmpty else { return }
            self.preview.hide()
            self.outline.entries = self.outlineEntries
            let entries = self.visualBands(height: self.bounds.height)
            let anchorY: CGFloat? = {
                guard let index = self.hoveredBandIndex,
                      entries.indices.contains(index) else { return point.y }
                return entries[index].y
            }()
            self.outline.show(rightOf: self, over: window, keyboard: false, anchorY: anchorY)
            self.updateMarkLayers(animated: true)
        }
        outlineWorkItem = work
        if dwell <= 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: work)
        }
    }

    private func cancelOutlineShow() {
        outlineWorkItem?.cancel()
        outlineWorkItem = nil
    }

    private func schedulePreviewHide() {
        previewHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerIsInPreview else { return }
            self.preview.hide()
            if !self.outline.isVisible, !self.pointerIsInOutline {
                self.updateHoveredBand(at: nil, animated: true)
                self.pointerLocation = nil
            }
        }
        previewHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewExitDelay, execute: work)
    }

    private func cancelPreviewHide() {
        previewHideWorkItem?.cancel()
        previewHideWorkItem = nil
    }

    private func scheduleOutlineHide() {
        outlineHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerIsInOutline else { return }
            self.outline.dismiss()
            if self.pointerLocation == nil {
                self.updateHoveredBand(at: nil, animated: true)
            }
        }
        outlineHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DensityOutlineWindow.hideDelay, execute: work)
    }

    private func cancelOutlineHide() {
        outlineHideWorkItem?.cancel()
        outlineHideWorkItem = nil
    }

    private func scrub(to event: NSEvent, showsSnippet: Bool, interactive: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        updateHoveredBand(at: point, animated: true)
        delegate?.densityGutter(self, didRequestScrollToFraction: fraction(at: point))
        showPreview(at: point, showsSnippet: showsSnippet, interactive: interactive)
    }

    private func showPreview(
        at point: NSPoint,
        showsSnippet: Bool,
        interactive: Bool = true
    ) {
        guard isScrubbing || hoveredBandIndex != nil else {
            preview.hide()
            return
        }
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
            reduceMotion: styleSheet.reduceMotion,
            interactive: interactive
        )
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            previewWorkItem?.cancel()
            previewWorkItem = nil
            cancelPreviewHide()
            cancelOutlineShow()
            cancelOutlineHide()
            pointerLocation = nil
            pointerIsInPreview = false
            pointerIsInOutline = false
            preview.hide()
            outline.dismiss()
            updateHoveredBand(at: nil, animated: false)
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
