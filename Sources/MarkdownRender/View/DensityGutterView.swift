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
    ///
    /// Scroll updates call this with `animated: false` — position changes
    /// during momentum scrolling do not need CA animation setup on every mark.
    /// Pointer-interaction code calls it with `animated: true` so the current
    /// heading glow and hovered mark transitions stay smooth.
    public var visibleRange: ClosedRange<CGFloat> = 0...1 {
        didSet {
            // Only animate if the *current* heading changed (user landed on a
            // new section); a simple scroll-by never animates so momentum
            // scrolling does not create CA animation objects per mark.
            let currentNow = currentHeadingFraction()
            let currentChanged = currentNow != previousCurrentFraction
            updateMarkLayers(animated: currentChanged)
        }
    }

    /// How far the reader has got, shaded behind everything (§5.1).
    /// Scroll-driven updates do not animate; mark opacity changes are cheap
    /// implicit transactions.
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
    /// Extra magnetic pull scaled by scrub velocity (points at full influence).
    static let scrubVelocityPull: CGFloat = 2.0
    /// Pointer speed (pt/s) that saturates velocity pull.
    static let scrubVelocityScale: CGFloat = 900
    /// Maximum fractional compression of the centred stack near the pointer.
    static let stackCompression: CGFloat = 0.08
    /// Whole-rail width scale while the pointer is inside.
    static let breatheScale: CGFloat = 1.08
    /// Alpha multiplier for marks outside the hovered neighbourhood.
    static let neighborhoodDim: CGFloat = 0.82
    /// Marks within this index distance stay slightly lifted under hover.
    static let neighborhoodLiftRadius: Int = 2
    /// Wider resting gap when the document has few headings.
    static let shortDocMarkGap: CGFloat = 18
    static let shortDocThreshold: Int = 3
    /// Optical boost on click / scrub release (points of extra width).
    static let jumpPunchBoost: CGFloat = 4
    /// Soft progress wash behind the stack.
    static let progressWashAlpha: CGFloat = 0.055
    /// Current-mark glow (same hue, very low opacity).
    static let currentGlowRadius: CGFloat = 10
    static let currentGlowOpacity: Float = 0.12

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
    private var railBreathe: CGFloat = 1
    private var punchBandIndex: Int?
    private var punchAmount: CGFloat = 0
    private var lastPointerSample: (y: CGFloat, time: CFTimeInterval)?
    private var pointerVelocityY: CGFloat = 0
    private var previousCurrentFraction: CGFloat?
    private var progressWashLayer: CALayer?
    private var endCapLayers: [CALayer] = []
    private var breatheWorkItem: DispatchWorkItem?

    /// The bars sit on a quiet, centred spine. The spine is deliberately
    /// narrower than the hit area so the map feels easy to scrub without
    /// becoming a second scrollbar.
    private let horizontalMargin: CGFloat = 16
    private let trackInset: CGFloat = 28
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

    /// Every resting heading uses one length. The old level-encoded staircase
    /// made a short outline look like randomly broken rules; heading depth is
    /// already explicit in the hover outline. Current / hover state grows the
    /// mark without moving its shared centre line.
    static func headingMarkWidth(level: Int, emphasized: Bool = false) -> CGFloat {
        _ = level
        return emphasized ? 30 : 24
    }

    /// Resting gap: short documents breathe so two lonely ticks do not look broken.
    static func restingMarkGap(count: Int, defaultGap: CGFloat = 10, shortGap: CGFloat = shortDocMarkGap) -> CGFloat {
        count > 0 && count < shortDocThreshold ? shortGap : defaultGap
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
            markGap: Self.restingMarkGap(count: visible.count),
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

    private func style(for kind: DensityBand.Kind, contrast: Bool, emphasized: Bool = false) -> BandStyle {
        let maxWidth = max(2, bounds.width - horizontalMargin * 2)
        switch kind {
        case .heading(let level):
            return BandStyle(
                widthPoints: min(Self.headingMarkWidth(level: level, emphasized: emphasized), maxWidth),
                minHeight: level <= 1 ? 2.5 : 2,
                color: styleSheet.railTick
            )
        case .searchHit:
            // Rare sparks: a touch wider / brighter than heading ticks.
            return BandStyle(
                widthPoints: min(14, maxWidth),
                minHeight: 2.5,
                color: styleSheet.searchHit.withAlphaComponent(contrast ? 1 : 0.92)
            )
        case .change(let changeKind):
            return BandStyle(
                widthPoints: min(16, maxWidth),
                minHeight: 3,
                color: styleSheet.changeColor(changeKind).withAlphaComponent(contrast ? 1 : 0.95)
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
        let currentChanged = current != previousCurrentFraction
        previousCurrentFraction = current
        let available = max(1, bounds.width - horizontalMargin * 2)
        let pointerY = pointerLocation?.y
        let velocityInfluence = min(1, abs(pointerVelocityY) / Self.scrubVelocityScale)
        let velocityPull = isScrubbing
            ? Self.scrubVelocityPull * velocityInfluence
            : 0
        let magneticCap = Self.magneticPull + velocityPull

        ensureChromeLayers()

        while markLayers.count < entries.count {
            let mark = CALayer()
            mark.cornerCurve = .continuous
            mark.masksToBounds = false
            layer?.addSublayer(mark)
            markLayers.append(mark)
        }

        for (index, entry) in entries.enumerated() {
            let isCurrent: Bool = {
                guard let current else { return false }
                if case .heading = entry.band.kind {
                    return entry.band.startFraction == current
                }
                return false
            }()
            let isPrimary = index == hoveredBandIndex
            let emphasized = isCurrent || isPrimary
            var bandStyle = style(
                for: entry.band.kind,
                contrast: styleSheet.increaseContrast,
                emphasized: emphasized
            )
            let distance = pointerY.map { abs(entry.y - $0) }
            let influence = distance.map {
                Self.proximityInfluence(distance: $0, radius: Self.proximityRadius)
            } ?? 0
            let focus = isPrimary ? max(influence, 0.78) : influence * 0.72
            let neighborhood = Self.neighborhoodFactor(
                index: index,
                hoveredIndex: hoveredBandIndex
            )

            if isCurrent {
                bandStyle.color = styleSheet.railTickCurrent.withAlphaComponent(0.92)
                bandStyle.minHeight = max(bandStyle.minHeight, 3)
            } else if case .heading = entry.band.kind {
                bandStyle.color = styleSheet.railTick.withAlphaComponent(
                    entry.band.startFraction <= readProgress ? 0.48 : 0.28
                )
            }

            if focus > 0.02 {
                switch entry.band.kind {
                case .heading:
                    let alpha = (isCurrent ? 0.92 : 0.52) + focus * (isCurrent ? 0.06 : 0.42)
                    bandStyle.color = styleSheet.railTickCurrent.withAlphaComponent(min(0.98, alpha))
                case .searchHit, .change:
                    bandStyle.color = bandStyle.color.withAlphaComponent(min(1, 0.88 + focus * 0.12))
                default:
                    break
                }
            }

            if neighborhood < 1, !isPrimary {
                bandStyle.color = bandStyle.color.withAlphaComponent(
                    bandStyle.color.alphaComponent * neighborhood
                )
            }

            let punch = (index == punchBandIndex) ? punchAmount * Self.jumpPunchBoost : 0
            let markWidth = min(
                available,
                (bandStyle.widthPoints + focus * 12 + punch) * railBreathe
            )
            let markHeight = bandStyle.minHeight + focus * 2.2 + punch * 0.15
            let magnetic = (pointerY.map { ($0 - entry.y) } ?? 0)
                * focus * (magneticCap / max(1, Self.proximityRadius))
            let markY = entry.y + max(-magneticCap, min(magneticCap, magnetic))
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
            let growing = frame.width > previousFrame.width + 0.25
                || frame.height > previousFrame.height + 0.15

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mark.cornerRadius = min(markHeight / 2, 2)
            mark.frame = frame
            mark.backgroundColor = bandStyle.color.cgColor
            mark.isHidden = false
            if isCurrent, !styleSheet.reduceMotion {
                mark.shadowColor = styleSheet.railTickCurrent.cgColor
                mark.shadowRadius = Self.currentGlowRadius
                mark.shadowOpacity = Self.currentGlowOpacity
                mark.shadowOffset = .zero
            } else {
                mark.shadowOpacity = 0
                mark.shadowRadius = 0
            }
            CATransaction.commit()

            guard animated, !styleSheet.reduceMotion else { continue }
            let settleThis = isCurrent && currentChanged
            let duration: TimeInterval = {
                if settleThis { return Motion.settle }
                return growing ? Motion.hoverGrow : Motion.hoverShrink
            }()
            let timing: CAMediaTimingFunction = settleThis
                ? CAMediaTimingFunction(controlPoints: 0.22, 1.15, 0.36, 1)
                : CAMediaTimingFunction(name: .easeOut)

            if frameChanged, previousFrame != .zero {
                let position = CABasicAnimation(keyPath: "position")
                position.fromValue = NSValue(
                    point: NSPoint(x: previousFrame.midX, y: previousFrame.midY)
                )
                position.toValue = NSValue(point: mark.position)
                position.duration = duration
                position.timingFunction = timing
                mark.add(position, forKey: "mark-position")

                if settleThis {
                    let widthSpring = CASpringAnimation(keyPath: "bounds")
                    widthSpring.fromValue = NSValue(
                        rect: previousFrame.offsetBy(
                            dx: -previousFrame.minX, dy: -previousFrame.minY
                        )
                    )
                    widthSpring.toValue = NSValue(rect: mark.bounds)
                    widthSpring.mass = 1
                    widthSpring.stiffness = 220
                    widthSpring.damping = 18
                    widthSpring.duration = widthSpring.settlingDuration
                    mark.add(widthSpring, forKey: "mark-bounds")
                } else {
                    let boundsAnimation = CABasicAnimation(keyPath: "bounds")
                    boundsAnimation.fromValue = NSValue(
                        rect: previousFrame.offsetBy(
                            dx: -previousFrame.minX, dy: -previousFrame.minY
                        )
                    )
                    boundsAnimation.toValue = NSValue(rect: mark.bounds)
                    boundsAnimation.duration = duration
                    boundsAnimation.timingFunction = timing
                    mark.add(boundsAnimation, forKey: "mark-bounds")
                }
            }

            if colorChanged, let previousColor {
                let colorAnimation = CABasicAnimation(keyPath: "backgroundColor")
                colorAnimation.fromValue = previousColor
                colorAnimation.toValue = bandStyle.color.cgColor
                colorAnimation.duration = duration
                colorAnimation.timingFunction = timing
                mark.add(colorAnimation, forKey: "mark-color")
            }

            if settleThis || (isCurrent && currentChanged) {
                let glow = CABasicAnimation(keyPath: "shadowOpacity")
                glow.fromValue = 0
                glow.toValue = Self.currentGlowOpacity
                glow.duration = Motion.settle
                glow.timingFunction = CAMediaTimingFunction(name: .easeOut)
                mark.add(glow, forKey: "mark-glow")
            }
        }

        for mark in markLayers.dropFirst(entries.count) {
            mark.removeAllAnimations()
            mark.shadowOpacity = 0
            mark.isHidden = true
        }

        updateProgressWash(entries: entries, animated: animated)
        updateEndCaps(entries: entries, animated: animated)
    }

    static func neighborhoodFactor(index: Int, hoveredIndex: Int?) -> CGFloat {
        guard let hoveredIndex else { return 1 }
        let distance = abs(index - hoveredIndex)
        if distance == 0 { return 1 }
        if distance <= neighborhoodLiftRadius { return 0.92 }
        return neighborhoodDim
    }

    private func ensureChromeLayers() {
        if progressWashLayer == nil {
            let wash = CALayer()
            wash.cornerCurve = .continuous
            wash.masksToBounds = true
            layer?.insertSublayer(wash, at: 0)
            progressWashLayer = wash
        }
        while endCapLayers.count < 2 {
            let cap = CALayer()
            cap.cornerCurve = .continuous
            cap.masksToBounds = true
            layer?.insertSublayer(cap, at: 0)
            endCapLayers.append(cap)
        }
    }

    /// Quiet completion trail: a soft wash from the stack top through read marks.
    private func updateProgressWash(
        entries: [(band: DensityBand, y: CGFloat)],
        animated: Bool
    ) {
        guard let wash = progressWashLayer else { return }
        let readEntries = entries.filter { $0.band.startFraction <= readProgress }
        guard let first = entries.first, let lastRead = readEntries.last, readProgress > 0.001 else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            wash.isHidden = true
            CATransaction.commit()
            return
        }

        let top = first.y - 6
        let bottom = lastRead.y + 6
        let height = max(4, bottom - top)
        let width: CGFloat = 6 * railBreathe
        let frame = CGRect(
            x: bounds.midX - width / 2,
            y: top,
            width: width,
            height: height
        )
        let color = styleSheet.railTick.withAlphaComponent(Self.progressWashAlpha).cgColor
        let previous = wash.presentation()?.frame ?? wash.frame

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.cornerRadius = width / 2
        wash.frame = frame
        wash.backgroundColor = color
        wash.isHidden = false
        CATransaction.commit()

        guard animated, !styleSheet.reduceMotion, previous != .zero, previous != frame else { return }
        let anim = CABasicAnimation(keyPath: "bounds")
        anim.fromValue = NSValue(rect: previous.offsetBy(dx: -previous.minX, dy: -previous.minY))
        anim.toValue = NSValue(rect: wash.bounds)
        anim.duration = Motion.settle
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        wash.add(anim, forKey: "wash-bounds")
        let pos = CABasicAnimation(keyPath: "position")
        pos.fromValue = NSValue(point: NSPoint(x: previous.midX, y: previous.midY))
        pos.toValue = NSValue(point: wash.position)
        pos.duration = Motion.settle
        pos.timingFunction = CAMediaTimingFunction(name: .easeOut)
        wash.add(pos, forKey: "wash-position")
    }

    /// Soft end-caps so one- or two-mark stacks do not float orphaned.
    private func updateEndCaps(
        entries: [(band: DensityBand, y: CGFloat)],
        animated: Bool
    ) {
        let showCaps = entries.count > 0 && entries.count < Self.shortDocThreshold
        let capSize: CGFloat = 2.5 * railBreathe
        let color = styleSheet.railTick.withAlphaComponent(0.16).cgColor
        let positions: [CGFloat] = {
            guard showCaps, let first = entries.first?.y, let last = entries.last?.y else {
                return []
            }
            let pad = Self.shortDocMarkGap * 0.85
            return [first - pad, last + pad]
        }()

        for (index, cap) in endCapLayers.enumerated() {
            guard showCaps, index < positions.count else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                cap.isHidden = true
                CATransaction.commit()
                continue
            }
            let y = positions[index]
            let frame = CGRect(
                x: bounds.midX - capSize / 2,
                y: y - capSize / 2,
                width: capSize,
                height: capSize
            )
            let previous = cap.presentation()?.frame ?? cap.frame
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cap.cornerRadius = capSize / 2
            cap.frame = frame
            cap.backgroundColor = color
            cap.isHidden = false
            CATransaction.commit()

            guard animated, !styleSheet.reduceMotion, previous != .zero, previous != frame else {
                continue
            }
            let anim = CABasicAnimation(keyPath: "position")
            anim.fromValue = NSValue(point: NSPoint(x: previous.midX, y: previous.midY))
            anim.toValue = NSValue(point: cap.position)
            anim.duration = Motion.breathe
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            cap.add(anim, forKey: "cap-position")
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
        }), abs(nearest.y - point.y) <= Self.hoverActivationSlop {
            return nearest.band.startFraction
        }
        let top = min(trackInset, max(0, bounds.height / 2))
        let bottom = max(top, bounds.height - trackInset)
        return min(1, max(0, (point.y - top) / max(1, bottom - top)))
    }

    /// Scrub release always settles on the nearest mark so the stick feels physical.
    private func snapFraction(at point: NSPoint) -> CGFloat {
        let entries = visualBands(height: bounds.height)
        if let nearest = entries.min(by: { abs($0.y - point.y) < abs($1.y - point.y) }) {
            return nearest.band.startFraction
        }
        return fraction(at: point)
    }

    private func samplePointerVelocity(at y: CGFloat) {
        let now = CACurrentMediaTime()
        if let last = lastPointerSample {
            let dt = now - last.time
            if dt > 0.001 && dt < 0.25 {
                let raw = (y - last.y) / CGFloat(dt)
                pointerVelocityY = pointerVelocityY * 0.35 + raw * 0.65
            }
        }
        lastPointerSample = (y, now)
    }

    private func setRailBreathe(_ target: CGFloat, animated: Bool) {
        guard abs(railBreathe - target) > 0.001 else { return }
        railBreathe = target
        updateMarkLayers(animated: animated)
    }

    private func performJumpPunch(at index: Int?) {
        guard let index else { return }
        punchBandIndex = index
        punchAmount = 1
        if !styleSheet.reduceMotion {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        updateMarkLayers(animated: true)

        let settle = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.punchAmount = 0
            self.punchBandIndex = nil
            self.updateMarkLayers(animated: true)
        }
        breatheWorkItem?.cancel()
        breatheWorkItem = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.jumpPunch * 0.45, execute: settle)
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
        pointerVelocityY = 0
        lastPointerSample = nil
        let point = convert(event.locationInWindow, from: nil)
        pointerLocation = point
        samplePointerVelocity(at: point.y)
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
        let point = convert(event.locationInWindow, from: nil)
        pointerLocation = point
        samplePointerVelocity(at: point.y)
        scrub(to: event, showsSnippet: true, interactive: false)
    }

    public override func mouseUp(with event: NSEvent) {
        let wasDragging = didDrag
        isScrubbing = false
        didDrag = false
        let point = convert(event.locationInWindow, from: nil)
        pointerLocation = point
        updateHoveredBand(at: point, animated: true)
        let target = wasDragging ? snapFraction(at: point) : fraction(at: point)
        delegate?.densityGutter(self, didRequestScrollToFraction: target)
        let punchIndex = visualBands(height: bounds.height).firstIndex {
            abs($0.band.startFraction - target) < 0.000_1
        } ?? hoveredBandIndex
        performJumpPunch(at: punchIndex)
        pointerVelocityY = 0
        lastPointerSample = nil
        if bounds.contains(point), hoveredBandIndex != nil {
            showPreview(at: point, showsSnippet: true)
        } else {
            cancelPreviewHide()
            preview.hide()
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
        samplePointerVelocity(at: point.y)
        updateHoveredBand(at: point, animated: true)
        guard hoveredBandIndex != nil else {
            previewWorkItem?.cancel()
            previewWorkItem = nil
            preview.hide()
            return
        }
        if preview.isVisible {
            showPreview(at: point, showsSnippet: true)
        } else {
            schedulePreview(at: point)
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cancelPreviewHide()
        pointerIsInPreview = false
        pointerLocation = point
        setRailBreathe(Self.breatheScale, animated: true)
        updateHoveredBand(at: point, animated: false)
        if hoveredBandIndex != nil {
            schedulePreview(at: point)
        }
    }

    public override func mouseExited(with event: NSEvent) {
        guard !isScrubbing else { return }
        previewWorkItem?.cancel()
        previewWorkItem = nil
        pointerLocation = nil
        pointerVelocityY = 0
        lastPointerSample = nil
        setRailBreathe(1, animated: true)
        updateMarkLayers(animated: true)
        guard preview.isVisible else {
            updateHoveredBand(at: nil, animated: true)
            return
        }
        schedulePreviewHide()
    }

    public func presentOutlineForKeyboard() {
        guard let window else { return }
        cancelPreviewHide()
        cancelOutlineShow()
        pointerIsInPreview = false
        preview.hide()
        outline.entries = outlineEntries
        outline.show(rightOf: self, over: window, keyboard: true)
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

    private func cancelOutlineShow() {
        outlineWorkItem?.cancel()
        outlineWorkItem = nil
    }

    private func schedulePreviewHide() {
        previewHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerIsInPreview else { return }
            self.preview.hide()
            self.updateHoveredBand(at: nil, animated: true)
            self.pointerLocation = nil
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
            breatheWorkItem?.cancel()
            breatheWorkItem = nil
            pointerLocation = nil
            pointerVelocityY = 0
            lastPointerSample = nil
            punchAmount = 0
            punchBandIndex = nil
            railBreathe = 1
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
