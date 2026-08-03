import AppKit
import MarkdownCore
import MarkdownRender

/// Toolbar progress ring (§8.5).
///
/// "A progress ring appears in the toolbar whenever a document has tasks."  It
/// is the only permanent-looking element the AI layer adds, and it earns that
/// by being a single glyph: a plan document that is 4/11 done should say so
/// without a panel being open.
final class TaskProgressRing: NSView {
    var progress: (done: Int, total: Int) = (0, 0) {
        didSet {
            let shouldHide = progress.total == 0
            if isHidden != shouldHide {
                isHidden = shouldHide
                invalidateIntrinsicContentSize()
                onVisibilityChange?(shouldHide)
            }
            updateAccessibility()
            needsDisplay = true
        }
    }

    var styleSheet: StyleSheet { didSet { needsDisplay = true } }

    /// Fired when the reader clicks the ring — typically opens the task panel.
    var onActivate: (() -> Void)?
    /// Lets the toolbar hide the item entirely when there are no tasks.
    var onVisibilityChange: ((Bool) -> Void)?

    private let lineWidth: CGFloat = 2.5

    /// Hosts build panels before they have a theme in hand and assign
    /// `styleSheet` immediately afterwards.
    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        isHidden ? .zero : NSSize(width: 22, height: 22)
    }

    private var fraction: CGFloat {
        guard progress.total > 0 else { return 0 }
        return min(1, max(0, CGFloat(progress.done) / CGFloat(progress.total)))
    }

    private func updateAccessibility() {
        let label = progress.total > 0
            ? "\(progress.done) of \(progress.total) tasks complete"
            : "No tasks"
        setAccessibilityLabel(label)
        setAccessibilityValueDescription(label)
        toolTip = progress.total > 0 ? "\(label) — Open Tasks" : label
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }

    override func resetCursorRects() {
        guard !isHidden else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = lineWidth / 2 + 1
        let square = min(bounds.width, bounds.height) - inset * 2
        guard square > 0 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = square / 2

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        styleSheet.rule.panelAlpha(0.9, increaseContrast: styleSheet.increaseContrast).setStroke()
        track.stroke()

        guard progress.total > 0, fraction > 0 else { return }

        // Clockwise from twelve o'clock, which is the direction every progress
        // ring on the platform turns.
        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: center, radius: radius,
            startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true
        )
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        styleSheet.accent.setStroke()
        arc.stroke()

        guard fraction >= 1 else { return }
        styleSheet.accent.panelAlpha(0.22, increaseContrast: styleSheet.increaseContrast).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2
        )).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
