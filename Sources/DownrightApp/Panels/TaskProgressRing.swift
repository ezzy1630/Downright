import AppKit
import CoreText
import MarkdownCore
import MarkdownRender

/// Toolbar progress ring (§8.5).
///
/// "A progress ring appears in the toolbar whenever a document has tasks."  It
/// is the only permanent-looking element the AI layer adds, and it earns that
/// by being a single glyph: a plan document that is 4/11 done should say so
/// without a panel being open.
///
/// The ring is a real button, not a static badge: it carries the same
/// hover/press feedback as the rest of the toolbar, animates the arc as the
/// plan changes, celebrates a fully completed plan with a checkmark pop, and
/// stays visibly "on" while the task panel is open (`isActive`) so the icon
/// never silently stops meaning "open Tasks".
final class TaskProgressRing: NSView {
    var progress: (done: Int, total: Int) = (0, 0) {
        didSet {
            guard progress.done != oldValue.done || progress.total != oldValue.total else { return }
            let shouldHide = progress.total == 0
            if isHidden != shouldHide {
                isHidden = shouldHide
                invalidateIntrinsicContentSize()
                onVisibilityChange?(shouldHide)
            }
            let targetFraction = fraction
            if animatedFraction != targetFraction {
                animateArc(to: targetFraction)
            }
            let complete = progress.total > 0 && progress.done >= progress.total
            if complete, !didCelebrateCompletion {
                didCelebrateCompletion = true
                celebrateCompletion()
            } else if !complete {
                didCelebrateCompletion = false
            }
            updateAccessibility()
            applyStyle()
        }
    }

    var styleSheet: StyleSheet {
        didSet {
            applyStyle()
            redrawLayers()
        }
    }

    /// Mirrors whether the task panel is open so the toolbar icon shows its
    /// on-state — the ring is the button that owns that panel (§8.5).
    var isActive: Bool = false {
        didSet {
            guard isActive != oldValue else { return }
            applyStyle()
            invalidateIntrinsicContentSize()
        }
    }

    /// Fired when the reader clicks the ring — typically opens the task panel.
    var onActivate: (() -> Void)?
    /// Lets the toolbar hide the item entirely when there are no tasks.
    var onVisibilityChange: ((Bool) -> Void)?

    private enum Metrics {
        static let size: CGFloat = 20
        static let lineWidth: CGFloat = 2
    }

    private let feedbackLayer = CALayer()
    private let discLayer = CAShapeLayer()
    private let trackLayer = CAShapeLayer()
    private let arcLayer = CAShapeLayer()
    private let checkLayer = CAShapeLayer()
    private var animatedFraction: CGFloat = 0
    private var didCelebrateCompletion = false
    private var trackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var isPressedForFeedback = false

    /// Hosts build panels before they have a theme in hand and assign
    /// `styleSheet` immediately afterwards.
    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.size, height: Metrics.size))
        isHidden = true
        wantsLayer = true

        feedbackLayer.opacity = 0
        layer?.insertSublayer(feedbackLayer, at: 0)
        buildLayers()

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAccessibility()
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        isHidden ? .zero : NSSize(width: Metrics.size, height: Metrics.size)
    }

    private func buildLayers() {
        guard let layer else { return }
        for sub in [discLayer, trackLayer, arcLayer, checkLayer] {
            sub.fillColor = NSColor.clear.cgColor
            layer.addSublayer(sub)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        feedbackLayer.frame = bounds.insetBy(dx: -1, dy: -1)
        feedbackLayer.cornerRadius = bounds.height / 2
        placeLayers()
        CATransaction.commit()
    }

    private func placeLayers() {
        let inset = Metrics.lineWidth / 2 + 1
        let square = min(bounds.width, bounds.height) - inset * 2
        guard square > 0 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = square / 2

        discLayer.frame = bounds
        discLayer.path = CGPath(ellipseIn: NSRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2
        ), transform: nil)

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        trackLayer.path = track.cgPath
        trackLayer.lineWidth = Metrics.lineWidth
        trackLayer.frame = bounds

        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: center, radius: radius,
            startAngle: 90, endAngle: 90 - 360, clockwise: true
        )
        arcLayer.frame = bounds
        arcLayer.path = arc.cgPath
        arcLayer.lineWidth = Metrics.lineWidth
        arcLayer.lineCap = .round
        arcLayer.strokeStart = 0
        arcLayer.strokeEnd = animatedFraction
        arcLayer.fillColor = NSColor.clear.cgColor

        checkLayer.frame = bounds
        checkLayer.path = Self.checkPath(in: bounds.insetBy(dx: 3.5, dy: 3.5))
        checkLayer.lineWidth = 1.8
        checkLayer.lineCap = .round
        checkLayer.lineJoin = .round
        checkLayer.strokeStart = 0
        checkLayer.strokeEnd = 0
    }

    /// The check is drawn in the view's (unflipped) coordinates: the vertex
    /// sits at the bottom, the short arm enters from the upper-left and the
    /// long arm finishes on the lower-right — the "✓" the reader writes, not
    /// a rotated caret.
    private static func checkPath(in rect: NSRect) -> CGPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + 1, y: rect.midY - 0.4))
        path.line(to: NSPoint(x: rect.midX - 0.8, y: rect.minY + 1.5))
        path.line(to: NSPoint(x: rect.maxX - 0.8, y: rect.maxY - 1.5))
        return path.cgPath
    }

    private var fraction: CGFloat {
        guard progress.total > 0 else { return 0 }
        return min(1, max(0, CGFloat(progress.done) / CGFloat(progress.total)))
    }

    // MARK: - Styling

    private func applyStyle() {
        let contrast = styleSheet.increaseContrast
        let complete = progress.total > 0 && progress.done >= progress.total

        feedbackLayer.backgroundColor = NSColor.labelColor.cgColor

        // The disc reads as "this toolbar button is the Tasks button": quiet
        // when idle, lit while the panel is open, solid accent once complete.
        discLayer.fillColor = (complete ? styleSheet.accent : styleSheet.text)
            .panelAlpha(complete ? 1 : (isActive ? 0.12 : 0), increaseContrast: contrast).cgColor

        trackLayer.strokeColor = styleSheet.rule
            .panelAlpha(0.9, increaseContrast: contrast)
            .withAlphaComponent(isActive ? 0.55 : 0.9)
            .cgColor

        arcLayer.strokeColor = styleSheet.accent
            .withAlphaComponent(complete ? 0 : 1)
            .cgColor

        checkLayer.strokeColor = styleSheet.background
            .panelAlpha(1, increaseContrast: false).cgColor

        let showsCheck = complete && !isHidden
        checkLayer.opacity = showsCheck ? 1 : 0
        trackLayer.opacity = showsCheck ? 0 : 1
        arcLayer.opacity = showsCheck ? 0 : (animatedFraction > 0 ? 1 : 0)
        discLayer.opacity = isActive || complete ? 1 : 0

        needsDisplay = true
    }

    private func redrawLayers() {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    // MARK: - Animation

    private func animateArc(to target: CGFloat) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduce else {
            animatedFraction = target
            arcLayer.strokeEnd = target
            arcLayer.opacity = target > 0 ? 1 : 0
            return
        }
        animatedFraction = target
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = arcLayer.presentation()?.strokeEnd ?? arcLayer.strokeEnd
        animation.toValue = target
        animation.duration = Motion.deliberate
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.82, 0.28, 1)
        arcLayer.add(animation, forKey: "arc")
        arcLayer.strokeEnd = target
        arcLayer.opacity = target > 0 ? 1 : 0
    }

    private func celebrateCompletion() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        checkLayer.strokeEnd = 1
        if reduce {
            arcLayer.opacity = 0
            checkLayer.opacity = 1
            discLayer.opacity = 1
            return
        }
        // The check draws in as the disc pops in underneath it: the last task
        // of a finished plan gets a moment, not a mutation.
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = Motion.standard
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        checkLayer.add(draw, forKey: "completion-check")

        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.72
        pop.toValue = 1
        pop.beginTime = Motion.quick
        pop.duration = Motion.deliberate
        pop.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.82, 0.28, 1)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Motion.quick

        let appear = CAAnimationGroup()
        appear.animations = [pop, fade]
        appear.duration = Motion.quick + Motion.deliberate
        discLayer.add(appear, forKey: "completion-fill")
        arcLayer.opacity = 0
    }

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        refreshInteractionFeedback(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        refreshInteractionFeedback(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        setPressedFeedback(true)
    }

    override func mouseDragged(with event: NSEvent) {
        setPressedFeedback(bounds.contains(convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        setPressedFeedback(false)
        if inside {
            onActivate?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }

    override func resetCursorRects() {
        guard !isHidden else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func setPressedFeedback(_ pressed: Bool) {
        guard pressed != isPressedForFeedback else { return }
        isPressedForFeedback = pressed
        refreshInteractionFeedback(animated: true)
        updatePressTransform(animated: true)
    }

    private func refreshInteractionFeedback(animated: Bool) {
        let state: ToolbarChromePolicy.InteractionState = if isPressedForFeedback {
            .pressed
        } else if isPointerInside {
            .hover
        } else {
            .idle
        }
        let targetOpacity = ToolbarChromePolicy.feedbackOpacity(
            for: state,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        animateFeedbackOpacity(to: targetOpacity, animated: animated)
    }

    private func animateFeedbackOpacity(to opacity: Float, animated: Bool) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reduce else {
            feedbackLayer.removeAnimation(forKey: "feedback-opacity")
            feedbackLayer.opacity = opacity
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = feedbackLayer.presentation()?.opacity ?? feedbackLayer.opacity
        animation.toValue = opacity
        animation.duration = ToolbarChromePolicy.hoverDuration
        animation.timingFunction = ToolbarChromePolicy.timingFunction()
        feedbackLayer.add(animation, forKey: "feedback-opacity")
        feedbackLayer.opacity = opacity
    }

    private func updatePressTransform(animated: Bool) {
        let scale = isPressedForFeedback ? ToolbarChromePolicy.pressedScale : 1
        let transform = CATransform3DMakeScale(scale, scale, 1)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reduce else {
            layer?.transform = transform
            return
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = layer?.presentation()?.transform ?? layer?.transform
        animation.toValue = transform
        animation.duration = isPressedForFeedback
            ? ToolbarChromePolicy.pressInDuration
            : ToolbarChromePolicy.pressOutDuration
        animation.timingFunction = ToolbarChromePolicy.timingFunction()
        layer?.add(animation, forKey: "press-transform")
        layer?.transform = transform
    }

    private func updateAccessibility() {
        let label = progress.total > 0
            ? "\(progress.done) of \(progress.total) tasks complete"
            : "No tasks"
        setAccessibilityLabel(label)
        setAccessibilityValueDescription(label)
        toolTip = progress.total > 0 ? "\(label) — Open Tasks" : label
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}

private extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath:
                path.closeSubpath()
            @unknown default:
                break
            }
        }
        return path
    }
}
