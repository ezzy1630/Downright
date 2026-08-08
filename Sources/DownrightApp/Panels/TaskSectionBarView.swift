import AppKit
import MarkdownCore
import MarkdownRender

/// Section-map progress bar (§8.5).
///
/// A whole-plan bar answers "how much is left"; this one answers "where is it
/// left".  One segment per document section, width proportional to its task
/// count, fill for its completion — the shape of the remaining work is visible
/// as geography before a single row is read.  Hovering a segment lights it and
/// hands its summary to the panel's caption; clicking scrolls the list to the
/// section, so the bar is a map rather than a meter.
///
/// The bar replaces the old header's percent figure, count caption, and plain
/// progress bar — three chrome elements that between them said one thing.
@MainActor
final class TaskSectionBarView: NSView {
    var segments: [TaskWorklist.Segment] = [] {
        didSet {
            if segments.count != oldValue.count { rebuildLayers() }
            placeSegments(animated: window != nil)
            updateAccessibility()
        }
    }

    var styleSheet: StyleSheet {
        didSet { applyStyle() }
    }

    /// The segment under the pointer, or nil as it leaves — the panel swaps
    /// its one-line caption for the hovered section's own count.
    var onHoverSegment: ((Int?) -> Void)?
    /// A click on a segment: the panel scrolls the matching section into view.
    var onSelectSegment: ((Int) -> Void)?

    /// Tall enough to round its own ends and to read as a bar rather than as a
    /// rule that happens to be orange.
    static let barHeight: CGFloat = 4
    /// The band a pointer can actually hit; the bar draws centred inside it.
    static let hitHeight: CGFloat = 28
    /// A sliver of backdrop between two segments, so sections read as separate
    /// blocks of work rather than as one gradient.
    static let gap: CGFloat = 2

    private struct SegmentLayers {
        let track = CALayer()
        let fill = CALayer()
    }

    private var segmentLayers: [SegmentLayers] = []
    private var trackingAreaRef: NSTrackingArea?
    private var hoveredIndex: Int? {
        didSet {
            guard hoveredIndex != oldValue else { return }
            applyStyle()
            // The bar answers the pointer physically: the segment under it
            // swells a step, the way a button's face warms on approach.
            placeSegments(animated: window != nil, duration: Motion.quick)
        }
    }
    private var pressedIndex: Int? {
        didSet {
            guard pressedIndex != oldValue else { return }
            placeSegments(animated: window != nil, duration: Motion.quick)
        }
    }
    private var keyboardIndex = 0

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.hitHeight)
    }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Progress by section")
        focusRingType = .default
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Layout

    override func layout() {
        super.layout()
        placeSegments(animated: false)
    }

    /// The segment's full extent, gaps reserved between neighbours.  A segment
    /// never narrows past the bar's own height: one task in a large plan still
    /// earns a visible, clickable block.
    private func segmentFrame(for index: Int) -> NSRect {
        let count = segments.count
        guard count > 0, index < count else { return .zero }
        let gaps = CGFloat(count - 1) * Self.gap
        let available = max(0, bounds.width - gaps)
        var x: CGFloat = 0
        for earlier in 0..<index {
            x += available * CGFloat(segments[earlier].weight) + Self.gap
        }
        let width = max(Self.barHeight, available * CGFloat(segments[index].weight))
        let height = barHeight(for: index)
        let y = (bounds.height - height) / 2
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Hover swells a segment one step, a press dips it — the same physics a
    /// row's surface answers with, in the bar's own vocabulary.
    private func barHeight(for index: Int) -> CGFloat {
        if index == pressedIndex { return Self.barHeight - 1 }
        if index == hoveredIndex { return Self.barHeight + 1.5 }
        return Self.barHeight
    }

    private func hitSegment(at point: NSPoint) -> Int? {
        guard !segments.isEmpty else { return nil }
        for index in segments.indices
        where segmentFrame(for: index).insetBy(dx: -Self.gap / 2, dy: -4).contains(point) {
            return index
        }
        return nil
    }

    private func rebuildLayers() {
        for pair in segmentLayers {
            pair.track.removeFromSuperlayer()
            pair.fill.removeFromSuperlayer()
        }
        segmentLayers = segments.map { _ in
            let pair = SegmentLayers()
            for layer in [pair.track, pair.fill] {
                layer.cornerRadius = Self.barHeight / 2
                // Geometry animates through the transaction `placeSegments`
                // wraps around each change — a glide when counts move, a quick
                // swell under the pointer, nothing at all when it asks for a
                // plain layout pass.
                self.layer?.addSublayer(layer)
            }
            return pair
        }
        applyStyle()
    }

    private func placeSegments(animated: Bool, duration: TimeInterval = Motion.deliberate) {
        guard segmentLayers.count == segments.count else { return }
        CATransaction.begin()
        if animated, !styleSheet.reduceMotion {
            // Implicit animation of the frame pair gives each segment one smooth
            // glide when a count changes — the travel the old bar had, kept.
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(Motion.timing(.decelerate))
        } else {
            CATransaction.setDisableActions(true)
        }
        for (index, pair) in segmentLayers.enumerated() {
            let frame = segmentFrame(for: index)
            // The caps stay perfectly round at whatever height the pointer
            // state gives the segment, so a swell never squares an end off.
            pair.track.cornerRadius = frame.height / 2
            pair.fill.cornerRadius = frame.height / 2
            pair.track.frame = frame
            // The fill keeps a minimum stub as soon as anything is done — a
            // full round cap, not a square sliver.  At zero the layer hides
            // outright: a 0-wide layer with a capsule corner radius still
            // rasterises its two semicircles, which meet as an hourglass
            // sliver in the gap between segments.
            let fraction = CGFloat(segments[index].completion)
            let fillWidth = fraction > 0 ? max(frame.height, frame.width * fraction) : 0
            pair.fill.isHidden = fillWidth == 0
            pair.fill.frame = NSRect(
                x: frame.minX, y: frame.minY, width: fillWidth, height: frame.height
            )
        }
        CATransaction.commit()
    }

    // MARK: - Style

    private func applyStyle() {
        let contrast = styleSheet.increaseContrast
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, pair) in segmentLayers.enumerated() {
            let hovered = index == hoveredIndex
            pair.track.backgroundColor = styleSheet.text
                .panelAlpha(hovered ? 0.2 : 0.1, increaseContrast: contrast).cgColor
            pair.fill.backgroundColor = styleSheet.accent.cgColor
            pair.fill.opacity = 1
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTrackingArea(
            &trackingAreaRef,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow]
        )
    }

    override func mouseMoved(with event: NSEvent) {
        let index = hitSegment(at: convert(event.locationInWindow, from: nil))
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        onHoverSegment?(index)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        onHoverSegment?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        pressedIndex = hitSegment(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let index = hitSegment(at: convert(event.locationInWindow, from: nil))
        if let index, index == pressedIndex { onSelectSegment?(index) }
        pressedIndex = nil
    }

    override func resetCursorRects() {
        for index in segments.indices {
            addCursorRect(segmentFrame(for: index).insetBy(dx: 0, dy: -4), cursor: .pointingHand)
        }
    }

    override var acceptsFirstResponder: Bool { !segments.isEmpty }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: keyboardIndex = max(0, keyboardIndex - 1)
        case 124: keyboardIndex = min(max(0, segments.count - 1), keyboardIndex + 1)
        case 36, 49:
            guard segments.indices.contains(keyboardIndex) else { return }
            onSelectSegment?(keyboardIndex)
        default: super.keyDown(with: event); return
        }
        onHoverSegment?(keyboardIndex)
        setNeedsDisplay(bounds)
    }

    // MARK: - Accessibility

    private func updateAccessibility() {
        let done = segments.reduce(0) { $0 + $1.doneCount }
        let total = segments.reduce(0) { $0 + $1.taskCount }
        setAccessibilityValue(total > 0 ? "\(done) of \(total) tasks done" : "No tasks")
        setAccessibilityCustomActions(segments.indices.map { index in
            let segment = segments[index]
            let action = NSAccessibilityCustomAction(
                name: "Open \(segment.title)",
                handler: { [weak self] in self?.onSelectSegment?(index); return true }
            )
            return action
        })
    }
}
