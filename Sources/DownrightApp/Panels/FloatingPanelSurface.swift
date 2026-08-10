import AppKit
import MarkdownRender

/// The transparent window boundary is intentional. `NSGlassEffectView` samples
/// the window below it; putting the floating body in the document window's
/// glass-container content tree makes the material see its own compositor
/// stage instead of the document. A child window is also exactly the hit-test
/// boundary of the visible body while its height is being poured out.
@MainActor
final class FloatingPanelWindow: NSWindow {
    weak var floatingSurface: FloatingPanelSurface?
    var onOutsideMouseDown: (() -> Void)?

    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // A floating child keeps the glass surface above the document while
        // the child relationship still lets AppKit sample the document below.
        level = .floating
        collectionBehavior = [.moveToActiveSpace]
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        setAccessibilityRole(.window)
        setAccessibilityLabel("Floating panel")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown,
           let floatingSurface
        {
            let point = floatingSurface.convert(event.locationInWindow, from: nil)
            if !floatingSurface.visibleBodyBoundsForHitTesting.contains(point) {
                onOutsideMouseDown?()
                return
            }
        }
        super.sendEvent(event)
    }
}

/// A detached panel body. The body owns the material and geometry; the
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
    /// Set by the owner when this body is the content of a child window. The
    /// spring remains on the surface, while the child window supplies the
    /// compositor and hit-test boundary.
    var onWindowFrameChange: ((NSRect) -> Void)?
    var onFrameSpringSettled: (() -> Void)?

    private let fallback: PanelBackdrop
    private let rimGradient = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private let revealMask = CAShapeLayer()
    private var glass: NSView?
    private var glassContent: NSView?
    private var glassLayoutContent: NSView?
    private var isHostingContentInGlass = false
    private var contentLayoutHeight: CGFloat = 0
    private var frameSpring = Motion.SpringRect(
        perceptualDuration: Motion.springDeliberate,
        bounce: 0.04
    )
    private var revealSpring = Motion.SpringScalar(
        value: 0,
        perceptualDuration: Motion.springDeliberate,
        bounce: 0.04
    )
    private var hasSpringFrame = false
    private var hasRevealSpring = false
    private var frameSpringMoving = false
    private var springMoving = false
    private var restingWindowFrame = NSRect.zero
    private var sliverWindowFrame = NSRect.zero
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
        addSubview(fallback, positioned: .below, relativeTo: nil)
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

    /// The child window stays at the final frame. The panel's content is laid
    /// out at that height while the body is a sliver clipped by the reveal
    /// mask, with its top edge pinned to the body's top edge.
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
            // The child window owns the current bounds. Temporarily giving the
            // content its measured width is enough for Auto Layout; the final
            // width is applied by the same rect spring as the height.
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
        updateSurfaceOpacity(for: frame)
        needsLayout = true
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
        let height = min(bounds.height, max(0, revealSpring.value))
        let progress = restingWindowFrame.height > sliverWindowFrame.height
            ? min(1, max(0, (height - sliverWindowFrame.height)
                / (restingWindowFrame.height - sliverWindowFrame.height)))
            : 1
        let radius = min(
            Top.cornerRadius * (0.55 + 0.45 * progress),
            min(bounds.width, max(1, height)) / 2
        )
        let visibleRect = NSRect(
            x: bounds.minX,
            y: bounds.maxY - height,
            width: bounds.width,
            height: height
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        revealMask.frame = bounds
        revealMask.path = PanelMetrics.continuousRoundedPath(rect: visibleRect, radius: radius)
        layer?.mask = height >= bounds.height - 0.5 ? nil : revealMask
        layer?.shadowPath = revealMask.path
        rimMask.frame = bounds
        rimMask.path = PanelMetrics.continuousRoundedPath(
            rect: visibleRect.insetBy(dx: 0.75, dy: 0.75),
            radius: max(0, radius - 0.75)
        )
        let scale = 0.97 + 0.03 * progress
        layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
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
        let contentFrame = NSRect(
            x: 0,
            y: bounds.height - layoutHeight,
            width: bounds.width,
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

    var currentWindowFrameForTesting: NSRect { frameSpring.rect }
    var contentLayoutHeightForTesting: CGFloat { contentLayoutHeight }

    // MARK: - Material

    static func supportsGlass(_ styleSheet: StyleSheet) -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        return !styleSheet.reduceTransparency && !styleSheet.increaseContrast
    }

    static func glassTint(_ styleSheet: StyleSheet) -> NSColor {
        let isDark = Self.isDarkBackground(styleSheet.background)
        if isDark {
            return NSColor(
                calibratedRed: 0.04, green: 0.08, blue: 0.14,
                alpha: styleSheet.increaseContrast ? 0.30 : 0.18
            )
        }
        return styleSheet.background.withAlphaComponent(
            styleSheet.increaseContrast ? 0.12 : 0.06
        )
    }

    private static func opaqueFallbackColor(_ styleSheet: StyleSheet) -> NSColor {
        styleSheet.surface.withAlphaComponent(1)
    }

    private static func isDarkBackground(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        let luminance = 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        return luminance < 0.5
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
                glassEffect?.tintColor = Self.glassTint(styleSheet)
                glassEffect?.alphaValue = 1
            }
        }
        applySurfaceStyle()
    }

    /// A glass view owns its content view. This is the topology AppKit can
    /// composite reliably; the child window then lets that material sample the
    /// document window beneath it instead of sampling a sibling in its own
    /// glass-container content view.
    @available(macOS 26.0, *)
    private func mountContentOnGlass() {
        // AppKit's glass must own the content view. Do not put a visual-effect
        // sibling underneath it: that makes the glass sample the wash instead
        // of the document window and turns Liquid Glass into a flat card.
        fallback.isHidden = true
        glass?.removeFromSuperview()
        let material = NSGlassEffectView()
        // Regular is Apple's frosted Liquid Glass treatment. The material
        // supplies the adaptive light response and samples the document
        // directly. Keep the tint low enough that the sampled scene remains
        // visible as colour and light rather than becoming a painted card.
        material.style = .regular
        material.tintColor = Self.glassTint(styleSheet)
        material.alphaValue = 1
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
        contentContainer.addSubview(layoutContent)
        layoutContent.addSubview(content)
        glassContent = contentContainer
        glassLayoutContent = layoutContent
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        content.frame = contentContainer.bounds
        isHostingContentInGlass = true
        PanelBackdrop.resolveDetachedGlass(in: content)
    }

    /// Glass is created before the child window exists so measurement can run
    /// without a window. Rebuild it once after attachment so AppKit binds the
    /// material to the document window it is meant to sample.
    func refreshGlassAfterWindowAttach() {
        guard usesGlass, #available(macOS 26.0, *) else { return }
        mountContentOnGlass()
        applySurfaceStyle()
    }

    var visibleBodyBoundsForHitTesting: NSRect {
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
        fallback.isHidden = false
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
        layer?.shadowOpacity = Float(styleSheet.increaseContrast ? 0.28 : 0.18)
        let isDark = Self.isDarkBackground(styleSheet.background)
        let specular = NSColor.white
        let rimAlpha = styleSheet.increaseContrast ? 0.92 : (isDark ? 0.72 : 0.85)
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
