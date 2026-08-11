import AppKit
import MarkdownRender

/// A floating panel body. The body owns the material and geometry; the
/// inspector host (when present) owns the one title/switcher header inside it.
/// That split is intentional: a floating Tasks panel and a floating History
/// panel must not grow two competing title rows.
@MainActor
final class FloatingPanelSurface: Motion.SpringSurfaceView {
    enum Top {
        /// The ceiling leaves a readable document margin below the toolbar.
        static let windowHeightFraction: CGFloat = 0.6
        static let minimumContentHeight: CGFloat = 132
        static let pourSliverHeight: CGFloat = 22
        static let cornerRadius: CGFloat = PanelMetrics.floatingSurfaceRadius
    }

    var styleSheet: StyleSheet {
        didSet {
            fallback.styleSheet = styleSheet
            fallback.opaqueSurfaceColor = Self.opaqueFallbackColor(styleSheet)
            if let host = content as? InspectorHostView { host.styleSheet = styleSheet }
            updateMaterial()
            applySurfaceStyle()
        }
    }

    let content: NSView

    var onClose: (() -> Void)?
    /// Optional frame owner. In-window surfaces leave this nil and let the
    /// spring update their frame directly.
    var onWindowFrameChange: ((NSRect) -> Void)?
    var onFrameSpringSettled: (() -> Void)?

    private let fallback: PanelBackdrop
    private let rimGradient = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private let arrivalGlint = CAShapeLayer()
    private let revealMask = CAShapeLayer()
    private var glass: NSView?
    private var glassContent: NSView?
    private var glassLayoutContent: NSView?
    private var isHostingContentInGlass = false
    private var contentLayoutHeight: CGFloat = 0
    private var frameSpring = Motion.SpringRect(
        perceptualDuration: Motion.liquidSettle,
        bounce: 0.055
    )
    private var revealSpring = Motion.SpringScalar(
        value: 0,
        perceptualDuration: Motion.liquidSettle,
        bounce: 0.07
    )
    private var hasSpringFrame = false
    private var hasRevealSpring = false
    private var frameSpringMoving = false
    private var springMoving = false
    private var restingWindowFrame = NSRect.zero
    private var sliverWindowFrame = NSRect.zero
    private var anchorWindowFrame = NSRect.zero
    private var isAnchorMorphing = false
    private(set) var isDismissing = false
    private(set) var usesGlass = false

    @available(macOS 26.0, *)
    private var glassEffect: NSGlassEffectView? { glass as? NSGlassEffectView }

    init(styleSheet: StyleSheet, content: NSView) {
        self.styleSheet = styleSheet
        self.content = content
        self.fallback = PanelBackdrop(styleSheet: styleSheet)
        super.init(frame: .zero)
        finishInit()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func finishInit() {
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 24
        layer?.shadowOffset = NSSize(width: 0, height: -8)
        layer?.shadowOpacity = Float(styleSheet.increaseContrast ? 0.34 : 0.22)

        rimMask.fillColor = NSColor.clear.cgColor
        rimMask.strokeColor = NSColor.white.cgColor
        rimMask.actions = [
            "path": NSNull(), "frame": NSNull(), "strokeColor": NSNull(),
        ]
        rimGradient.mask = rimMask
        rimGradient.actions = [
            "frame": NSNull(), "colors": NSNull(),
        ]
        rimGradient.zPosition = 100
        layer?.addSublayer(rimGradient)

        arrivalGlint.fillColor = NSColor.clear.cgColor
        arrivalGlint.strokeColor = NSColor.white.withAlphaComponent(0.62).cgColor
        arrivalGlint.lineWidth = 1.15
        arrivalGlint.lineCap = .round
        arrivalGlint.opacity = 0
        arrivalGlint.zPosition = 101
        arrivalGlint.actions = [
            "path": NSNull(), "frame": NSNull(), "opacity": NSNull(),
            "strokeStart": NSNull(), "strokeEnd": NSNull(),
        ]
        layer?.addSublayer(arrivalGlint)

        revealMask.fillColor = NSColor.black.cgColor
        revealMask.actions = ["path": NSNull(), "frame": NSNull()]
        layer?.mask = revealMask

        fallback.blendsWithinWindow = false
        // Reduce Transparency is an explicit user choice. The fallback stays
        // opaque, but it must read as a panel surface rather than borrowing
        // the document's paper colour and disappearing into the page.
        fallback.usesSurfaceFill = true
        fallback.opaqueSurfaceColor = Self.opaqueFallbackColor(styleSheet)
        fallback.veilAlpha = 0
        fallback.autoresizingMask = [.width, .height]
        fallback.frame = bounds
        // Native glass must be the first material the compositor ever sees.
        // Installing the opaque fallback and removing it later still exposes
        // one painted frame while NSGlassEffectView attaches to its window.
        if !Self.supportsGlass(styleSheet) {
            addSubview(fallback, positioned: .below, relativeTo: nil)
        }
        mountContentOnSelf()
        setAccessibilityRole(.group)
        setAccessibilityLabel(content.accessibilityLabel() ?? "Floating panel")
        updateMaterial()
        applySurfaceStyle()
    }

    // MARK: - Geometry

    /// The host calls this once before the surface is shown. It avoids a
    /// zero-frame first paint while preserving the spring's state for later
    /// content-driven refits.
    func setRestingFrame(_ frame: NSRect) {
        frameSpring.snap(to: frame)
        hasSpringFrame = true
        applyFrame(frame)
        if !hasRevealSpring {
            revealSpring.snap(to: frame.height)
            hasRevealSpring = true
            applyReveal()
        }
    }

    /// The panel's content is laid out at its final height while the body is a
    /// sliver clipped by the reveal mask, with both top edges pinned together.
    func configureWindowFrames(
        resting: NSRect,
        sliver: NSRect,
        contentHeight: CGFloat
    ) {
        restingWindowFrame = resting
        sliverWindowFrame = sliver
        contentLayoutHeight = max(0, contentHeight)
        guard hasRevealSpring else { return }
        revealSpring.target(isDismissing ? sliver.height : resting.height)
    }

    func presentFromSliver(animated: Bool) {
        isDismissing = false
        if !hasSpringFrame { setRestingFrame(sliverWindowFrame) }
        revealSpring.snap(to: sliverWindowFrame.height)
        applyReveal()
        guard animated, !styleSheet.reduceMotion else {
            revealSpring.snap(to: restingWindowFrame.height)
            applyReveal()
            onFrameSpringSettled?()
            return
        }
        revealSpring.target(restingWindowFrame.height)
        armSprings()
    }

    func dismissToSliver(animated: Bool) {
        isDismissing = true
        guard animated, !styleSheet.reduceMotion else {
            revealSpring.snap(to: sliverWindowFrame.height)
            applyReveal()
            onFrameSpringSettled?()
            return
        }
        revealSpring.target(sliverWindowFrame.height)
        armSprings()
    }

    /// Prime the actual panel at the invoking control's host-space frame. No
    /// surrogate is involved: native material, rounded shape, and eventual
    /// panel are one view for the whole trip.
    func prepareAnchorPresentation(from anchor: NSRect) {
        guard Self.isUsableAnchor(anchor) else {
            isAnchorMorphing = false
            setRestingFrame(restingWindowFrame)
            return
        }
        isDismissing = false
        isAnchorMorphing = true
        anchorWindowFrame = anchor
        frameSpring.snap(to: anchor)
        revealSpring.snap(to: anchor.height)
        hasSpringFrame = true
        hasRevealSpring = true
        content.alphaValue = 0
        applyFrame(anchor)
        applyReveal()
    }

    func startAnchorPresentation(animated: Bool) {
        guard isAnchorMorphing else { return }
        guard animated, !styleSheet.reduceMotion else {
            frameSpring.snap(to: restingWindowFrame)
            revealSpring.snap(to: restingWindowFrame.height)
            applyFrame(restingWindowFrame)
            applyReveal()
            finishAnchorMorph()
            onFrameSpringSettled?()
            return
        }
        frameSpring.target(restingWindowFrame)
        revealSpring.target(restingWindowFrame.height)
        armSprings()
    }

    func dismissToAnchor(_ anchor: NSRect, animated: Bool) {
        guard Self.isUsableAnchor(anchor) else {
            dismissToSliver(animated: animated)
            return
        }
        isDismissing = true
        isAnchorMorphing = true
        anchorWindowFrame = anchor
        guard animated, !styleSheet.reduceMotion else {
            frameSpring.snap(to: anchor)
            revealSpring.snap(to: anchor.height)
            applyFrame(anchor)
            applyReveal()
            onFrameSpringSettled?()
            return
        }
        frameSpring.target(anchor)
        revealSpring.target(anchor.height)
        armSprings()
    }

    /// Deterministic landing hook for geometry tests. Production motion still
    /// uses the display-link spring; tests should inspect both the sliver
    /// first frame and the settled target without sleeping the main run loop.
    func settleForTesting() { springsSettleImmediately() }

    /// Gives Auto Layout the width it will actually receive before asking for
    /// a fitting height. The old path measured an unhosted inspector at zero
    /// width, so its scroll view reported only its first row.
    func prepareForMeasurement(width: CGFloat, height: CGFloat) {
        let size = NSSize(width: width, height: max(1, height))
        if onWindowFrameChange == nil {
            if frame.size != size { frame.size = size }
        } else {
            // An external frame owner supplies current bounds. Giving content
            // its measured width is enough for Auto Layout; the same rect
            // spring applies the final width and height.
            frame.size.width = size.width
        }
        contentLayoutHeight = max(contentLayoutHeight, size.height)
        layoutSubtreeIfNeeded()
        content.layoutSubtreeIfNeeded()
    }

    func setContentLayoutHeight(_ height: CGFloat) {
        contentLayoutHeight = max(0, height)
        needsLayout = true
    }

    /// Height changes use the shared rect spring. A resize can retarget both
    /// axes, but a live resize settles immediately so the trailing edge stays
    /// welded to the window while the user drags it.
    func retargetFrame(_ frame: NSRect, animated: Bool) {
        if !hasSpringFrame { setRestingFrame(self.frame) }
        guard animated, !styleSheet.reduceMotion, window != nil, !inLiveResize else {
            frameSpring.snap(to: frame)
            revealSpring.snap(to: isDismissing ? sliverWindowFrame.height : frame.height)
            applyFrame(frame)
            applyReveal()
            return
        }
        frameSpring.target(frame)
        armSprings()
    }

    override func springTick(dt: CGFloat) -> Bool {
        frameSpringMoving = frameSpring.advance(dt: dt)
        let revealMoving = revealSpring.advance(dt: dt)
        springMoving = frameSpringMoving || revealMoving
        return springMoving
    }

    override func springApply() {
        if frameSpringMoving { applyFrame(frameSpring.rect) }
        applyReveal()
        guard !springMoving else { return }
        if isAnchorMorphing, !isDismissing { finishAnchorMorph() }
        onFrameSpringSettled?()
    }

    override func springsSettleImmediately() {
        frameSpring.snap(to: frameSpring.target)
        revealSpring.snap(to: revealSpring.target)
        frameSpringMoving = false
        springMoving = false
        applyFrame(frameSpring.rect)
        applyReveal()
        onFrameSpringSettled?()
    }

    private func applyFrame(_ frame: NSRect) {
        if let onWindowFrameChange {
            onWindowFrameChange(frame)
        } else {
            self.frame = frame
        }
        if isAnchorMorphing {
            updateAnchorMorphVisuals(for: frame)
        } else {
            updateSurfaceOpacity(for: frame)
        }
        needsLayout = true
    }

    private func updateAnchorMorphVisuals(for frame: NSRect) {
        let widthSpan = restingWindowFrame.width - anchorWindowFrame.width
        let raw = abs(widthSpan) > 0.5
            ? (frame.width - anchorWindowFrame.width) / widthSpan
            : 1
        let progress = Self.clampedUnit(raw)
        // Keep type out of the elastic phase. It resolves only once the glass
        // has enough area to carry a stable layout, then arrives quickly.
        let contentProgress = Self.clampedUnit((progress - 0.56) / 0.28)
        let smooth = contentProgress * contentProgress * (3 - 2 * contentProgress)
        content.alphaValue = smooth
        alphaValue = 1
        let radius = anchorWindowFrame.height / 2
            + (Top.cornerRadius - anchorWindowFrame.height / 2) * progress
        if #available(macOS 26.0, *) { glassEffect?.cornerRadius = radius }
        layer?.shadowOpacity = Float((styleSheet.increaseContrast ? 0.28 : 0.14) * progress)
        rimGradient.opacity = Float(progress)
    }

    private func finishAnchorMorph() {
        isAnchorMorphing = false
        content.alphaValue = 1
        if #available(macOS 26.0, *) { glassEffect?.cornerRadius = Top.cornerRadius }
        rimGradient.opacity = 1
        applySurfaceStyle()
    }

    private static func clampedUnit(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private static func isUsableAnchor(_ rect: NSRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width > 1
            && rect.height > 1
    }

    private func updateSurfaceOpacity(for frame: NSRect) {
        guard sliverWindowFrame.height > 0,
              restingWindowFrame.height > sliverWindowFrame.height
        else {
            alphaValue = 1
            return
        }
        let span = restingWindowFrame.height - sliverWindowFrame.height
        let progress = min(1, max(0, (frame.height - sliverWindowFrame.height) / span))
        let sliverOpacity = Motion.floatingSurfaceSliverOpacity
        alphaValue = min(
            1,
            sliverOpacity + (1 - sliverOpacity) * progress
                / Motion.floatingSurfacePresenceFraction
        )
    }

    private func applyReveal() {
        guard bounds.height > 0 else { return }
        if isAnchorMorphing {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.mask = nil
            let radius = min(Top.cornerRadius, min(bounds.width, bounds.height) / 2)
            rimMask.frame = bounds
            rimMask.path = Self.topRimPath(
                rect: bounds.insetBy(dx: 0.75, dy: 0.75),
                radius: max(0, radius - 0.75)
            )
            arrivalGlint.frame = bounds
            arrivalGlint.path = rimMask.path
            CATransaction.commit()
            return
        }
        let height = min(bounds.height, max(0, revealSpring.value))
        let progress = restingWindowFrame.height > sliverWindowFrame.height
            ? min(1, max(0, (height - sliverWindowFrame.height)
                / (restingWindowFrame.height - sliverWindowFrame.height)))
            : 1
        let radius = min(
            Top.cornerRadius * (0.55 + 0.45 * progress),
            min(bounds.width, max(1, height)) / 2
        )
        // Inflate from the toolbar-facing corner. Exposing a full-width strip
        // on frame one looked like a backing panel arriving before the glass.
        let seedWidth = min(44, bounds.width)
        // The top edge spreads before the body finishes dropping, like a
        // liquid sheet finding its container rather than a box scaling up.
        let widthProgress = 1 - pow(1 - progress, 1.65)
        let visibleWidth = seedWidth + (bounds.width - seedWidth) * widthProgress
        let visibleRect = NSRect(
            x: bounds.maxX - visibleWidth,
            y: bounds.maxY - height,
            width: visibleWidth,
            height: height
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        revealMask.frame = bounds
        revealMask.path = PanelMetrics.continuousRoundedPath(rect: visibleRect, radius: radius)
        layer?.mask = height >= bounds.height - 0.5 ? nil : revealMask
        layer?.shadowPath = revealMask.path
        rimMask.frame = bounds
        let rimRect = visibleRect.insetBy(dx: 0.75, dy: 0.75)
        rimMask.path = usesGlass
            ? Self.topRimPath(rect: rimRect, radius: max(0, radius - 0.75))
            : PanelMetrics.continuousRoundedPath(
                rect: rimRect,
                radius: max(0, radius - 0.75)
            )
        arrivalGlint.frame = bounds
        arrivalGlint.path = rimMask.path
        // The mask owns geometry. Scaling the full layer around its centre
        // made the visible body drift away from its toolbar anchor.
        layer?.setAffineTransform(.identity)
        CATransaction.commit()
        updateSurfaceOpacity(for: NSRect(
            x: restingWindowFrame.minX,
            y: restingWindowFrame.minY,
            width: restingWindowFrame.width,
            height: height
        ))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        fallback.frame = bounds
        glass?.frame = bounds

        let layoutHeight = max(bounds.height, contentLayoutHeight)
        let layoutWidth = isAnchorMorphing
            ? max(restingWindowFrame.width, bounds.width)
            : bounds.width
        let contentFrame = NSRect(
            x: bounds.width - layoutWidth,
            y: bounds.height - layoutHeight,
            width: layoutWidth,
            height: layoutHeight
        )
        if glass != nil, let glassContent, let glassLayoutContent {
            // `contentView` is managed by AppKit rather than Auto Layout. It
            // stays at the current body bounds. A child inside it owns the
            // final content frame even when only its top sliver is visible.
            glassContent.frame = bounds
            glassLayoutContent.frame = contentFrame
            content.frame = glassLayoutContent.bounds
            glassLayoutContent.layoutSubtreeIfNeeded()
            glassContent.layoutSubtreeIfNeeded()
        }
        if !isHostingContentInGlass { content.frame = contentFrame }

        rimGradient.frame = bounds
        applyReveal()
    }

    var fittedContentHeight: CGFloat {
        if let host = content as? InspectorHostView {
            return host.floatingFittingHeight
        }
        let height = content.fittingSize.height
        return height.isFinite && height > 0 ? height : 0
    }

    var preferredWidth: CGFloat {
        (content as? PanelSurface)?.preferredWidth ?? PanelMetrics.detailWidth
    }

    /// The frame the surface is actually resting at — the single source of
    /// truth for where a morph flight should land. The floating host's
    /// re-derivation of this frame can drift a few points from it (minimum
    /// heights, clamp order), which is exactly the drift that leaves a glass
    /// slab resting slightly off the card it is about to become.
    var restingWindowFrameForMorph: NSRect { restingWindowFrame }

    var currentWindowFrameForTesting: NSRect { frameSpring.rect }
    var contentLayoutHeightForTesting: CGFloat { contentLayoutHeight }

    // MARK: - Material

    static func supportsGlass(_ styleSheet: StyleSheet) -> Bool {
        ChromeGlass.supportsGlass(styleSheet)
    }

    static func glassTint(_ styleSheet: StyleSheet) -> NSColor {
        ChromeGlass.glassTint(styleSheet, tint: .panel)
    }

    private static func opaqueFallbackColor(_ styleSheet: StyleSheet) -> NSColor {
        ChromeGlass.opaqueFallbackColor(styleSheet, tint: .panel)
    }

    private static func glassMaterialAlpha(_ styleSheet: StyleSheet) -> CGFloat {
        // Clear glass keeps the document legible as context, but a panel full
        // of text still needs enough optical density that prose beneath it
        // cannot compete with task labels. Keep refraction visible while
        // following Apple's guidance to strengthen material behind fine text.
        isDarkBackground(styleSheet.background) ? 0.78 : 0.84
    }

    private static func isDarkBackground(_ color: NSColor) -> Bool {
        ChromeGlass.isDarkBackground(color)
    }

    private func updateMaterial() {
        let wantsGlass = Self.supportsGlass(styleSheet)
        switch (usesGlass, wantsGlass) {
        case (false, false):
            if isHostingContentInGlass || content.superview !== self { mountContentOnSelf() }
        case (false, true):
            usesGlass = true
            if #available(macOS 26.0, *) {
                mountContentOnGlass()
            }
        case (true, false):
            usesGlass = false
            mountContentOnSelf()
        case (true, true):
            if #available(macOS 26.0, *) {
                glassEffect?.appearance = ChromeGlass.materialAppearance(styleSheet)
                glassEffect?.tintColor = Self.glassTint(styleSheet)
                glassEffect?.alphaValue = Self.glassMaterialAlpha(styleSheet)
            }
        }
        applySurfaceStyle()
    }

    /// Material and controls are siblings. The material stays partially
    /// transparent from its first frame; controls remain fully opaque and do
    /// not inherit the material's alpha.
    @available(macOS 26.0, *)
    private func mountContentOnGlass() {
        // The native material still owns an empty content view, which keeps
        // its compositor topology valid. Actual controls sit above it so the
        // material can stay translucent without fading labels or hit targets.
        fallback.removeFromSuperview()
        glass?.removeFromSuperview()
        let material = NSGlassEffectView()
        // The document supplies the panel's colour; regular glass adds the
        // adaptive blur and optical edge. Its tint remains page-derived and
        // deliberately low so the body does not become a painted card.
        // Clear glass preserves the document as visible context throughout the
        // trip; regular glass resolves too close to a painted card in dark mode.
        material.style = .clear
        material.appearance = ChromeGlass.materialAppearance(styleSheet)
        material.tintColor = Self.glassTint(styleSheet)
        material.alphaValue = Self.glassMaterialAlpha(styleSheet)
        if material.responds(to: Selector(("setEffectIsInteractive:"))) {
            material.setValue(true, forKey: "effectIsInteractive")
        }
        material.cornerRadius = Top.cornerRadius
        material.wantsLayer = true
        material.layer?.cornerCurve = .continuous
        material.autoresizingMask = [.width, .height]
        material.frame = bounds
        material.clipsToBounds = true
        addSubview(material, positioned: .above, relativeTo: nil)
        glass = material

        content.removeFromSuperview()
        let contentContainer = NSView(frame: bounds)
        contentContainer.autoresizingMask = [.width, .height]
        contentContainer.clipsToBounds = true
        material.contentView = contentContainer
        let layoutContent = NSView(frame: bounds)
        layoutContent.wantsLayer = false
        layoutContent.clipsToBounds = true
        addSubview(layoutContent, positioned: .above, relativeTo: material)
        layoutContent.addSubview(content)
        glassContent = contentContainer
        glassLayoutContent = layoutContent
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        content.frame = contentContainer.bounds
        isHostingContentInGlass = true
        PanelBackdrop.resolveDetachedGlass(in: content)
    }

    /// Glass is created before attachment so measurement can run without a
    /// window. Attaching that same view to the document stage keeps its
    /// material identity continuous; this refresh changes properties only.
    func refreshGlassAfterWindowAttach() {
        guard usesGlass, #available(macOS 26.0, *) else { return }
        glassEffect?.appearance = ChromeGlass.materialAppearance(styleSheet)
        glassEffect?.tintColor = Self.glassTint(styleSheet)
        glassEffect?.alphaValue = Self.glassMaterialAlpha(styleSheet)
        applySurfaceStyle()
    }

    var glassIdentityForTesting: ObjectIdentifier? {
        glass.map(ObjectIdentifier.init)
    }
    var glassAlphaForTesting: CGFloat? { glass?.alphaValue }
    var contentSharesGlassOpacityForTesting: Bool {
        guard let glass else { return false }
        return content.isDescendant(of: glass)
    }
    var opaqueFallbackIsMountedForTesting: Bool { fallback.superview != nil }

    var visibleBodyBoundsForHitTesting: NSRect {
        if isAnchorMorphing { return bounds }
        let height = min(bounds.height, max(0, revealSpring.value))
        return NSRect(
            x: bounds.minX,
            y: bounds.maxY - height,
            width: bounds.width,
            height: height
        )
    }

    var visibleBodyHeightForTesting: CGFloat { visibleBodyBoundsForHitTesting.height }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard visibleBodyBoundsForHitTesting.contains(point) else { return nil }
        return super.hitTest(point)
    }

    private func mountContentOnSelf() {
        glass?.removeFromSuperview()
        glass = nil
        if fallback.superview !== self {
            fallback.frame = bounds
            addSubview(fallback, positioned: .below, relativeTo: nil)
        }
        if isHostingContentInGlass { content.removeFromSuperview() }
        glassContent = nil
        glassLayoutContent = nil
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        if content.superview !== self { addSubview(content) }
        content.frame = bounds
        isHostingContentInGlass = false
        PanelBackdrop.resolveDetachedGlass(in: content)
    }

    private func applySurfaceStyle() {
        layer?.shadowRadius = styleSheet.increaseContrast ? 42 : 40
        layer?.shadowOffset = NSSize(width: 0, height: -10)
        layer?.shadowOpacity = Float(styleSheet.increaseContrast ? 0.28 : 0.14)
        let isDark = Self.isDarkBackground(styleSheet.background)
        let specular = NSColor.white
        let rimAlpha = styleSheet.increaseContrast ? 0.92 : (isDark ? 0.58 : 0.72)
        let mutedAlpha = styleSheet.increaseContrast ? 0.24 : 0.08
        rimGradient.colors = [
            specular.withAlphaComponent(rimAlpha).cgColor,
            specular.withAlphaComponent(rimAlpha * 0.44).cgColor,
            specular.withAlphaComponent(mutedAlpha).cgColor,
            specular.withAlphaComponent(mutedAlpha * 0.35).cgColor,
        ]
        rimGradient.startPoint = CGPoint(x: 0.08, y: 0.98)
        rimGradient.endPoint = CGPoint(x: 0.92, y: 0.02)
        rimMask.lineWidth = styleSheet.increaseContrast ? 1.5 : 1.0
        // Native glass already draws its adaptive optical edge. The custom
        // path adds only the bright top specular, never a second perimeter.
        rimGradient.isHidden = false

        layer?.cornerRadius = usesGlass ? 0 : Top.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        if !usesGlass {
            fallback.wantsLayer = true
            fallback.layer?.cornerRadius = Top.cornerRadius
            fallback.layer?.cornerCurve = .continuous
            fallback.layer?.masksToBounds = true
        }
        needsDisplay = true
    }

    /// Native glass supplies the body edge. This path adds only the reference
    /// card's top specular, avoiding a second full perimeter stroke.
    private static func topRimPath(rect: NSRect, radius: CGFloat) -> CGPath {
        let radius = min(radius, min(rect.width, rect.height) / 2)
        let path = CGMutablePath()
        let kappa: CGFloat = 0.552_284_75
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.maxY),
            control1: CGPoint(x: rect.minX, y: rect.maxY - radius + radius * kappa),
            control2: CGPoint(x: rect.minX + radius - radius * kappa, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
            control1: CGPoint(x: rect.maxX - radius + radius * kappa, y: rect.maxY),
            control2: CGPoint(x: rect.maxX, y: rect.maxY - radius + radius * kappa)
        )
        return path
    }

    /// Prime content while the travelling glass is still the visible body.
    /// The six-point lift is small enough to keep text rasterised at its final
    /// size; it only gives the handoff a direction when content condenses in.
    func prepareForMorphArrival() {
        isDismissing = false
        content.wantsLayer = true
        content.layer?.removeAnimation(forKey: "floating-content-arrival")
        content.layer?.transform = CATransform3DMakeTranslation(0, -6, 0)
    }

    func prepareForMorphDismissal() {
        isDismissing = true
        arrivalGlint.removeAllAnimations()
        content.layer?.removeAnimation(forKey: "floating-content-arrival")
    }

    /// The vessel calls this at the empty-glass handoff. Content and the
    /// system material then land together instead of the list appearing only
    /// after the card has stopped moving.
    func playMorphArrivalDetails() {
        guard !styleSheet.reduceMotion, window != nil else {
            content.layer?.transform = CATransform3DIdentity
            return
        }
        let settle = CAKeyframeAnimation(keyPath: "transform")
        settle.values = [
            CATransform3DMakeTranslation(0, -6, 0),
            CATransform3DMakeTranslation(0, 1, 0),
            CATransform3DIdentity,
        ]
        settle.keyTimes = [0, 0.76, 1]
        settle.duration = Motion.liquidSettle
        settle.timingFunctions = [
            Motion.timing(.structural), Motion.timing(.decelerate),
        ]
        content.layer?.transform = CATransform3DIdentity
        content.layer?.add(settle, forKey: "floating-content-arrival")

        arrivalGlint.removeAllAnimations()
        arrivalGlint.strokeStart = 0
        arrivalGlint.strokeEnd = 1
        let start = CABasicAnimation(keyPath: "strokeStart")
        start.fromValue = 0
        start.toValue = 0.82
        let end = CABasicAnimation(keyPath: "strokeEnd")
        end.fromValue = 0.08
        end.toValue = 1
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 0.42, 0]
        opacity.keyTimes = [0, 0.38, 1]
        let group = CAAnimationGroup()
        group.animations = [start, end, opacity]
        group.duration = Motion.liquidSettle
        group.timingFunction = Motion.timing(.structural)
        arrivalGlint.add(group, forKey: "floating-arrival-glint")
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func cancelOperation(_ sender: Any?) { onClose?() }

    /// Tests use this to assert the material has a drawable body after layout;
    /// frame-only tests cannot catch a glass view mounted at `.zero`.
    var rendersBodyForTesting: Bool {
        bounds.width > 0 && bounds.height > 0
            && (glass?.bounds.width ?? fallback.bounds.width) > 0
            && (glass?.bounds.height ?? fallback.bounds.height) > 0
    }
}
