import AppKit
import CoreText
import MarkdownCore
import MarkdownRender

/// Toolbar progress ring (§8.5).
///
/// It is the Tasks button, and it is the only permanent-looking element the
/// task layer adds to the toolbar.  It earns that by answering two questions
/// without a panel being open — *is there a plan* and *how much of it is left* —
/// and by staying a button in every state, including the state where the
/// document has no tasks at all.  A control that vanishes when its count is
/// zero takes its own empty state with it, and takes the only pointer path to
/// the panel with it too.
///
/// The glyph is a ring, a remaining count, and nothing else:
///
/// * no tasks — a quiet empty track.  Nothing to say, still clickable.
/// * some done — an accent arc from twelve o'clock plus the number of tasks
///   still open, which is the figure a reader acts on.
/// * all done — the ring closes and a check draws in its centre.
///
/// The arc travels rather than jumps, the count crossfades, and the panel-open
/// state lights the disc, so the icon never silently stops meaning "Tasks".
final class TaskProgressRing: NSView {
    var progress: (done: Int, total: Int) = (0, 0) {
        didSet {
            guard progress.done != oldValue.done || progress.total != oldValue.total else { return }
            let hadTasks = oldValue.total > 0
            animateArc(to: fraction)
            updateCount(animated: window != nil)
            let complete = isComplete
            if complete, !didCelebrateCompletion {
                didCelebrateCompletion = true
                celebrateCompletion()
            } else if !complete {
                didCelebrateCompletion = false
            }
            updateAccessibility()
            applyStyle()
            // The item's label and tooltip change when a document gains or
            // loses its plan; the toolbar caches both until it revalidates.
            if hadTasks != (progress.total > 0) { onVisibilityChange?(false) }
        }
    }

    var styleSheet: StyleSheet {
        didSet {
            applyStyle()
            needsLayout = true
        }
    }

    /// Mirrors whether the task panel is open so the toolbar icon shows its
    /// on-state — the ring is the button that owns that panel (§8.5).
    var isActive: Bool = false {
        didSet {
            guard isActive != oldValue else { return }
            // Opening the panel hands it the numbers, so the ring stops
            // repeating them — see `countText`.
            updateCount(animated: window != nil)
            applyStyle(animated: true)
        }
    }

    /// Fired when the reader clicks the ring — typically opens the task panel.
    var onActivate: (() -> Void)?
    /// Kept for hosts that ask the toolbar to revalidate when the ring's
    /// meaning changes.  The ring itself is never hidden: see the type comment.
    var onVisibilityChange: ((Bool) -> Void)?

    private enum Metrics {
        /// The glyph.  Two points larger than it was, because the count has to
        /// sit inside it and 20pt could not hold two digits.
        static let ring: CGFloat = 22
        /// The button.  30pt with a 1pt plate inset is `ToolbarMenuButton`'s
        /// geometry to the point: the ring sat at 28 and so carried a hover
        /// plate two points smaller than the one beside it, which is exactly
        /// the kind of near-miss that makes a toolbar look assembled rather
        /// than drawn.
        static let control: CGFloat = 30
        static let lineWidth: CGFloat = 2.5
        static let plateRadius: CGFloat = 7
        static let countSize: CGFloat = 9.5
    }

    private static let countFont = NSFont.monospacedDigitSystemFont(
        ofSize: Metrics.countSize, weight: .semibold
    )

    private let feedbackLayer = CALayer()
    /// Everything the ring *is*, in one container.
    ///
    /// The press used to scale the whole view — plate, hit area and all — so
    /// the gesture read as "a toolbar button was pushed" with the ring along
    /// for the ride.  Giving the glyph its own layer lets the circle be the
    /// thing that answers: it compresses, springs back, and throws the wave
    /// that the panel then unfolds out of, while the plate underneath stays
    /// still and keeps doing its one job (saying the pointer is here).
    private let glyphLayer = CALayer()
    private let discLayer = CAShapeLayer()
    private let trackLayer = CAShapeLayer()
    private let arcLayer = CAShapeLayer()
    private let checkLayer = CAShapeLayer()
    private let countLayer = CATextLayer()
    /// The sonar ping a successful press emits — the panel's arrival told in
    /// the ring's own shape, rather than in a grey plate alone.
    private let pingLayer = CAShapeLayer()
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
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.control, height: Metrics.control))
        wantsLayer = true

        feedbackLayer.opacity = 0
        layer?.insertSublayer(feedbackLayer, at: 0)
        glyphLayer.actions = ["position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(glyphLayer)
        for sub in [discLayer, trackLayer, arcLayer, checkLayer] {
            sub.fillColor = NSColor.clear.cgColor
            glyphLayer.addSublayer(sub)
        }
        pingLayer.fillColor = NSColor.clear.cgColor
        pingLayer.opacity = 0
        pingLayer.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull()]
        // Outside the glyph container: the wave has to keep travelling while
        // the ring springs back, not inherit the spring.
        layer?.addSublayer(pingLayer)
        countLayer.alignmentMode = .center
        countLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        glyphLayer.addSublayer(countLayer)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAccessibility()
        updateCount(animated: false)
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Metrics.control, height: Metrics.control)
    }

    /// A toolbar lives inside the titlebar's draggable region. Explicitly
    /// claiming the pointer prevents a double-click on this custom NSView from
    /// leaking through to the titlebar and miniaturizing the window.
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - Geometry

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        feedbackLayer.frame = bounds.insetBy(dx: 1, dy: 1)
        feedbackLayer.cornerRadius = Metrics.plateRadius
        glyphLayer.frame = bounds
        placeLayers()
        CATransaction.commit()
    }

    private func placeLayers() {
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = (min(Metrics.ring, min(bounds.width, bounds.height)) - Metrics.lineWidth) / 2
        guard radius > 0 else { return }
        let square = NSRect(x: centre.x - radius, y: centre.y - radius,
                            width: radius * 2, height: radius * 2)

        for sub in [discLayer, trackLayer, arcLayer, checkLayer] { sub.frame = glyphLayer.bounds }

        // The ping rides the track's circle exactly, so the wave leaves from
        // the ring the reader pressed, not from some rect near it.
        pingLayer.frame = bounds
        pingLayer.lineWidth = Metrics.lineWidth

        // The lit disc stops at the inside of the track, so the panel-open
        // state fills the ring's core rather than washing over the ring itself.
        discLayer.path = CGPath(
            ellipseIn: square.insetBy(dx: Metrics.lineWidth / 2, dy: Metrics.lineWidth / 2),
            transform: nil
        )

        let track = NSBezierPath()
        track.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
        trackLayer.path = track.cgPath
        trackLayer.lineWidth = Metrics.lineWidth
        pingLayer.path = track.cgPath

        // Twelve o'clock, clockwise — the direction a reader reads a dial.
        let arc = NSBezierPath()
        arc.appendArc(withCenter: centre, radius: radius,
                      startAngle: 90, endAngle: 90 - 360, clockwise: true)
        arcLayer.path = arc.cgPath
        arcLayer.lineWidth = Metrics.lineWidth
        arcLayer.lineCap = .round
        arcLayer.strokeStart = 0
        // Layout must not undo state: re-placing the paths used to reset the
        // arc and wipe the completion check, so a finished plan drew as a bare
        // accent disc the moment the toolbar laid out again.
        arcLayer.strokeEnd = animatedFraction

        checkLayer.path = Self.checkPath(in: square.insetBy(dx: radius * 0.34, dy: radius * 0.34))
        checkLayer.lineWidth = 1.8
        checkLayer.lineCap = .round
        checkLayer.lineJoin = .round
        checkLayer.strokeStart = 0
        checkLayer.strokeEnd = isComplete ? 1 : 0

        // A `CATextLayer` draws from the top of its bounds, so the count is
        // centred by giving the layer exactly one line and centring that —
        // not by nudging a taller box half a point at a time.
        let font = Self.countFont
        let lineHeight = ceil(font.ascender - font.descender)
        countLayer.frame = NSRect(x: 0, y: (centre.y - lineHeight / 2).rounded(),
                                  width: bounds.width, height: lineHeight)
    }

    /// The check is drawn in the view's (unflipped) coordinates from the same
    /// unit tick the checkbox and the document renderer use, so "done" is one
    /// mark everywhere in the app (§8.5).
    private static func checkPath(in rect: NSRect) -> CGPath {
        let path = NSBezierPath()
        for (index, unit) in PanelCheckbox.Geometry.tick.enumerated() {
            let point = NSPoint(x: rect.minX + unit.x * rect.width,
                                y: rect.minY + unit.y * rect.height)
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        return path.cgPath
    }

    private var fraction: CGFloat {
        guard progress.total > 0 else { return 0 }
        return min(1, max(0, CGFloat(progress.done) / CGFloat(progress.total)))
    }

    private var isComplete: Bool { progress.total > 0 && progress.done >= progress.total }

    private var remaining: Int { max(0, progress.total - progress.done) }

    /// What the reader acts on is what is left, not what is finished.  Three
    /// digits will not fit a 22pt ring, so a very long plan says "99+" and the
    /// tooltip carries the exact figure.
    /// The numeral inside the ring — and the two states that deliberately have
    /// none.  A single remaining task is useful information at a glance, so
    /// the ring keeps the compact numeral for every short plan as well as for
    /// larger plans.  The open-panel and all-done states deliberately drop it:
    /// the panel owns the tally while open, and the checkmark owns completion.
    /// The count is never lost: `updateAccessibility` and the tooltip spell it
    /// out in words in every state.
    private var countText: String {
        guard progress.total > 0, !isComplete, !isActive else { return "" }
        return remaining > 99 ? "99+" : "\(remaining)"
    }

    /// Internal read-only hook for focused UI tests. The drawn text remains
    /// owned by the layer; tests only need to verify which states expose it.
    var countTextForTesting: String { countText }

    // MARK: - Styling

    /// Every colour the ring wears, set in one place.
    ///
    /// Assigning a `CAShapeLayer`'s colours outside a transaction hands each
    /// one Core Animation's default quarter-second implicit animation — a
    /// duration the motion system does not have and a fade Reduce Motion never
    /// hears about.  Styling is therefore instantaneous by default, and the one
    /// styling change a reader watches (the panel opening) asks for `quick`.
    private func applyStyle(animated: Bool = false) {
        CATransaction.begin()
        if animated, !styleSheet.reduceMotion, window != nil {
            CATransaction.setAnimationDuration(Motion.quick)
            CATransaction.setAnimationTimingFunction(Motion.timing(.easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        defer { CATransaction.commit() }

        let contrast = styleSheet.increaseContrast
        let complete = isComplete
        let hasTasks = progress.total > 0

        feedbackLayer.backgroundColor = NSColor.labelColor.cgColor

        // Open panel: the whole glyph tints.  The core lights and the track
        // takes the accent instead of the rule, so "this is the button that is
        // on" is said in the button's own colour rather than in grey — and the
        // track stays legible against the lit core, which a neutral rule at
        // the same value could not.
        discLayer.fillColor = styleSheet.accent
            .panelAlpha(isActive ? 0.13 : 0, increaseContrast: contrast).cgColor
        discLayer.opacity = isActive ? 1 : 0

        // An empty plan keeps its track, one step quieter: the button is still
        // there, it simply has nothing to report.  The track is a fraction of
        // the text colour rather than the rule, because a toolbar glyph has to
        // hold its shape against a warm paper *and* a warm dark toolbar, and
        // only the text token is guaranteed to sit opposite the background.
        trackLayer.strokeColor = isActive
            ? styleSheet.accent.panelAlpha(0.34, increaseContrast: contrast).cgColor
            : styleSheet.text.panelAlpha(hasTasks ? 0.20 : 0.12, increaseContrast: contrast).cgColor
        trackLayer.opacity = 1

        arcLayer.strokeColor = styleSheet.accent.cgColor
        arcLayer.opacity = animatedFraction > 0 ? 1 : 0

        checkLayer.strokeColor = styleSheet.accent.cgColor
        checkLayer.opacity = complete ? 1 : 0

        countLayer.foregroundColor = (contrast ? styleSheet.text : styleSheet.textSecondary).cgColor
        countLayer.font = Self.countFont as CTFont
        countLayer.fontSize = Metrics.countSize
    }

    // MARK: - Animation

    private func animateArc(to target: CGFloat) {
        let previous = animatedFraction
        animatedFraction = target
        guard !styleSheet.reduceMotion, window != nil else {
            arcLayer.removeAnimation(forKey: "arc")
            arcLayer.strokeEnd = target
            arcLayer.opacity = target > 0 ? 1 : 0
            return
        }
        // The arc travels.  Ticking one task of eleven moves it nine degrees,
        // and a jump that small is invisible — the travel is what the eye
        // catches, which is the whole point of putting progress in the toolbar.
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = arcLayer.presentation()?.strokeEnd ?? previous
        animation.toValue = target
        animation.duration = Motion.standard
        animation.timingFunction = Motion.timing(.decelerate)
        arcLayer.add(animation, forKey: "arc")
        arcLayer.strokeEnd = target
        arcLayer.opacity = target > 0 ? 1 : 0
    }

    private func updateCount(animated: Bool) {
        let text = countText
        guard countLayer.string as? String != text else { return }
        guard animated, !styleSheet.reduceMotion else {
            countLayer.removeAnimation(forKey: "count")
            countLayer.string = text
            return
        }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = Motion.quick
        countLayer.add(fade, forKey: "count")
        countLayer.string = text
    }

    private func celebrateCompletion() {
        guard !styleSheet.reduceMotion, window != nil else {
            checkLayer.strokeEnd = 1
            checkLayer.opacity = 1
            return
        }
        // The last task of a plan gets a moment, not a mutation: the ring
        // closes (that is `animateArc`, already running), then the check draws
        // itself and the whole glyph lands with one short pop.
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.beginTime = CACurrentMediaTime() + Motion.quick
        draw.duration = Motion.standard
        draw.timingFunction = Motion.timing(.easeOut)
        draw.fillMode = .backwards
        checkLayer.removeAnimation(forKey: "completion-check")
        checkLayer.add(draw, forKey: "completion-check")
        checkLayer.strokeEnd = 1
        checkLayer.opacity = 1

        let pop = Motion.pop(
            from: 0.9,
            overshoot: 1.08,
            duration: Motion.deliberate,
            travelAxis: CGVector(dx: 0, dy: 1)
        )
        pop.beginTime = CACurrentMediaTime() + Motion.quick
        pop.fillMode = .backwards
        glyphLayer.add(pop, forKey: "completion-pop")
    }

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTrackingArea(&trackingArea, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited])
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
        if inside {
            releasePressedFeedbackForActivation()
            playReleaseMoment()
            onActivate?()
        } else {
            setPressedFeedback(false)
        }
    }

    /// The moment the press hands off to the panel.
    ///
    /// This is the ring's half of one gesture: the circle springs back out of
    /// its compression and throws a wave outward, and the inspector's own
    /// arrival unfurls downward on the same clock (`InspectorHostView`
    /// borrows `Motion.deliberate` for exactly this reason).  Read together
    /// they say the panel came *out of the ring* rather than appearing beside
    /// it.  The wave runs a shade wider and softer than a plain button's
    /// acknowledgement, because it has further to carry.
    ///
    /// Reduce Motion keeps the state change and drops the moment entirely.
    private func playReleaseMoment() {
        guard !styleSheet.reduceMotion, window != nil else {
            glyphLayer.transform = CATransform3DIdentity
            return
        }

        let pop = Motion.pop(
            from: ToolbarChromePolicy.ringPressedScale,
            overshoot: 1.12,
            travelAxis: CGVector(dx: 0, dy: 1)
        )
        glyphLayer.removeAnimation(forKey: "press-transform")
        glyphLayer.add(pop, forKey: "press-transform")
        glyphLayer.transform = CATransform3DIdentity

        pingLayer.removeAnimation(forKey: "ping-grow")
        pingLayer.removeAnimation(forKey: "ping-fade")
        pingLayer.strokeColor = styleSheet.accent.cgColor
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak pingLayer] in
            pingLayer?.opacity = 0
            pingLayer?.transform = CATransform3DIdentity
        }
        CATransaction.setDisableActions(true)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 2.1
        grow.duration = Motion.deliberate
        grow.timingFunction = Motion.timing(.structural)
        pingLayer.add(grow, forKey: "ping-grow")
        pingLayer.transform = CATransform3DMakeScale(2.1, 2.1, 1)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.5
        fade.toValue = 0
        fade.duration = Motion.deliberate
        fade.timingFunction = Motion.timing(.easeOut)
        pingLayer.add(fade, forKey: "ping-fade")
        pingLayer.opacity = 0
        CATransaction.commit()
    }

    // MARK: - Keyboard

    /// Tab reaches the ring and Space or Return opens the panel: the toolbar's
    /// pointer path and its keyboard path are the same action (§11.4).
    ///
    /// Gated on Full Keyboard Access, like every AppKit control that is not a
    /// text field.  Without the gate the window makes the ring first responder
    /// on the click that opens the panel, and the ring then wears a system
    /// focus ring — a cobalt rectangle around the one round glyph in the
    /// toolbar, which is what made the button look mis-placed.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 1, dy: 1) }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: Metrics.plateRadius, yRadius: Metrics.plateRadius
        ).fill()
    }

    override func keyDown(with event: NSEvent) {
        switch KeyBinding.key(for: event) {
        case "space", "return":
            playReleaseMoment()
            onActivate?()
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        playReleaseMoment()
        onActivate?()
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func setPressedFeedback(_ pressed: Bool) {
        guard pressed != isPressedForFeedback else { return }
        isPressedForFeedback = pressed
        refreshInteractionFeedback(animated: true)
        updatePressTransform(animated: true)
    }

    /// Release inside skips the plain scale-back: the release moment's spring
    /// owns the transform from here, so the two never fight over one key.
    private func releasePressedFeedbackForActivation() {
        guard isPressedForFeedback else { return }
        isPressedForFeedback = false
        refreshInteractionFeedback(animated: true)
    }

    private func refreshInteractionFeedback(animated: Bool) {
        // A press does not darken the plate.  Two things moving at once —
        // a deepening rectangle and a compressing circle — is what made the
        // gesture read as "button" instead of "ring"; the plate holds its
        // hover value and the glyph carries the whole press.
        let state: ToolbarChromePolicy.InteractionState =
            isPressedForFeedback || isPointerInside ? .hover : .idle
        let targetOpacity = ToolbarChromePolicy.feedbackOpacity(
            for: state,
            increaseContrast: styleSheet.increaseContrast
        )
        animateFeedbackOpacity(to: targetOpacity, animated: animated)
    }

    private func animateFeedbackOpacity(to opacity: Float, animated: Bool) {
        guard animated, !styleSheet.reduceMotion else {
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
        let scale = isPressedForFeedback ? ToolbarChromePolicy.ringPressedScale : 1
        let transform = CATransform3DMakeScale(scale, scale, 1)
        guard animated, !styleSheet.reduceMotion else {
            glyphLayer.transform = transform
            return
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = glyphLayer.presentation()?.transform ?? glyphLayer.transform
        animation.toValue = transform
        animation.duration = isPressedForFeedback
            ? ToolbarChromePolicy.pressInDuration
            : ToolbarChromePolicy.pressOutDuration
        animation.timingFunction = ToolbarChromePolicy.timingFunction()
        glyphLayer.add(animation, forKey: "press-transform")
        glyphLayer.transform = transform
    }

    /// The count in words, always — this is where the figure lives now that the
    /// glyph only draws a numeral past ten (`countText`).  A tooltip that said
    /// "3 of 7 tasks complete" while the ring showed nothing would leave the
    /// remainder to arithmetic, so it names what is left as well.
    private func updateAccessibility() {
        guard progress.total > 0 else {
            setAccessibilityLabel("No tasks")
            setAccessibilityValueDescription("No tasks")
            toolTip = "No tasks — Open Tasks"
            return
        }
        let progressLabel = "\(progress.done) of \(progress.total) tasks complete"
        let tail = isComplete
            ? "all done"
            : (remaining == 1 ? "1 left" : "\(remaining) left")
        setAccessibilityLabel(progressLabel)
        setAccessibilityValueDescription(progressLabel)
        toolTip = "\(progressLabel), \(tail) — Open Tasks"
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        countLayer.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
    }
}
