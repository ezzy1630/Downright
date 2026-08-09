import AppKit
import MarkdownRender

/// The transparent window boundary is intentional. `NSGlassEffectView` samples
/// the window below it; putting the floating body in the document window's
/// glass-container content tree makes the material see its own compositor
/// stage instead of the document. A child window is also exactly the hit-test
/// boundary of the visible body while its height is being poured out.
@MainActor
final class FloatingPanelWindow: NSWindow {
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
        level = .floating
        collectionBehavior = [.moveToActiveSpace]
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
        static let cornerRadius: CGFloat = PanelMetrics.surfaceRadius
    }

    var styleSheet: StyleSheet {
        didSet {
            fallback.styleSheet = styleSheet
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
    private var glass: NSView?
    private var glassContent: NSView?
    private var glassLayoutContent: NSView?
    private var isHostingContentInGlass = false
    private var contentLayoutHeight: CGFloat = 0
    private var frameSpring = Motion.SpringRect(
        perceptualDuration: Motion.springDeliberate,
        bounce: 0.04
    )
    private var hasSpringFrame = false
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

        fallback.blendsWithinWindow = false
        fallback.veilAlpha = 0.06
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
    }

    /// A child window keeps the body clipped to its visible frame. The panel's
    /// content is still laid out at this final height while the body is a
    /// sliver, with its top edge pinned to the body's top edge.
    func configureWindowFrames(
        resting: NSRect,
        sliver: NSRect,
        contentHeight: CGFloat
    ) {
        restingWindowFrame = resting
        sliverWindowFrame = sliver
        contentLayoutHeight = max(0, contentHeight)
    }

    func presentFromSliver(animated: Bool) {
        isDismissing = false
        if !hasSpringFrame { setRestingFrame(sliverWindowFrame) }
        guard animated, !styleSheet.reduceMotion else {
            frameSpring.snap(to: restingWindowFrame)
            applyFrame(frameSpring.rect)
            onFrameSpringSettled?()
            return
        }
        frameSpring.target(restingWindowFrame)
        armSprings()
    }

    func dismissToSliver(animated: Bool) {
        isDismissing = true
        guard animated, !styleSheet.reduceMotion else {
            frameSpring.snap(to: sliverWindowFrame)
            applyFrame(frameSpring.rect)
            onFrameSpringSettled?()
            return
        }
        frameSpring.target(sliverWindowFrame)
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
            applyFrame(frame)
            return
        }
        frameSpring.target(frame)
        armSprings()
    }

    override func springTick(dt: CGFloat) -> Bool {
        let moving = frameSpring.advance(dt: dt)
        springMoving = moving
        return moving
    }

    override func springApply() {
        applyFrame(frameSpring.rect)
        guard !springMoving else { return }
        onFrameSpringSettled?()
    }

    override func springsSettleImmediately() {
        frameSpring.snap(to: frameSpring.target)
        springMoving = false
        applyFrame(frameSpring.rect)
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
        alphaValue = sliverOpacity + (1 - sliverOpacity) * progress
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

        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: Top.cornerRadius,
            cornerHeight: Top.cornerRadius,
            transform: nil
        )
        rimGradient.frame = bounds
        rimMask.frame = bounds
        rimMask.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
            cornerWidth: max(0, Top.cornerRadius - 0.75),
            cornerHeight: max(0, Top.cornerRadius - 0.75),
            transform: nil
        )
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
        styleSheet.background.withAlphaComponent(
            styleSheet.increaseContrast ? 0.18 : 0.10
        )
    }

    private func updateMaterial() {
        let wantsGlass = Self.supportsGlass(styleSheet)
        switch (usesGlass, wantsGlass) {
        case (false, false):
            if isHostingContentInGlass || content.superview !== self { mountContentOnSelf() }
        case (false, true):
            usesGlass = true
            if #available(macOS 26.0, *) { mountContentOnGlass() }
        case (true, false):
            usesGlass = false
            mountContentOnSelf()
        case (true, true):
            if #available(macOS 26.0, *) {
                glassEffect?.tintColor = Self.glassTint(styleSheet)
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
        fallback.isHidden = true
        glass?.removeFromSuperview()
        let material = NSGlassEffectView()
        // Clear keeps the document's texture legible through the body; the
        // system still supplies the blur, refraction, and specular edge.
        material.style = .clear
        material.tintColor = Self.glassTint(styleSheet)
        material.cornerRadius = Top.cornerRadius
        material.autoresizingMask = [.width, .height]
        material.frame = bounds
        material.clipsToBounds = true
        addSubview(material, positioned: .below, relativeTo: nil)
        glass = material

        content.removeFromSuperview()
        let contentContainer = NSView(frame: bounds)
        contentContainer.autoresizingMask = [.width, .height]
        contentContainer.wantsLayer = false
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
        layer?.shadowOpacity = Float(styleSheet.increaseContrast ? 0.34 : 0.22)
        let rimAlpha = styleSheet.increaseContrast ? 0.68 : 0.46
        let mutedAlpha = styleSheet.increaseContrast ? 0.24 : 0.10
        rimGradient.colors = [
            styleSheet.text.withAlphaComponent(rimAlpha).cgColor,
            styleSheet.text.withAlphaComponent(rimAlpha * 0.82).cgColor,
            styleSheet.text.withAlphaComponent(mutedAlpha).cgColor,
            styleSheet.text.withAlphaComponent(mutedAlpha * 0.55).cgColor,
        ]
        rimGradient.startPoint = CGPoint(x: 0.02, y: 1.0)
        rimGradient.endPoint = CGPoint(x: 0.98, y: 0.0)
        rimMask.lineWidth = styleSheet.increaseContrast ? 1.5 : 1.15

        layer?.cornerRadius = usesGlass ? 0 : Top.cornerRadius
        layer?.masksToBounds = false
        if !usesGlass {
            fallback.wantsLayer = true
            fallback.layer?.cornerRadius = Top.cornerRadius
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
