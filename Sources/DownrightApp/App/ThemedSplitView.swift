import AppKit
import MarkdownRender

/// A split view whose divider belongs to the theme.
///
/// `NSSplitView` paints a thin divider in a system grey that all but vanishes
/// against a themed page: two columns of prose meet with no seam, and the one
/// piece of chrome saying "this is draggable" is invisible.  Drawing it in
/// `rule` puts the seam at the same weight as every other separator in the app,
/// and hovering lifts a short segment of it into a grip.
///
/// Deliberately no animation: a hairline that crossfades on every pass of the
/// pointer is a distraction in a window meant for reading, and the resize
/// cursor AppKit already shows arrives at the same moment.
final class ThemedSplitView: NSSplitView {
    private enum Grip {
        /// Length of the brightened segment along the divider.
        static let length: CGFloat = 26
        /// A hairline you must land on exactly is not an affordance.  Hover
        /// resolves over a band wide enough to find without aiming.
        static let slop: CGFloat = 3
    }

    var styleSheet: StyleSheet {
        didSet { needsDisplay = true }
    }

    private var hoveredBand: NSRect?
    private var hoverTracking: NSTrackingArea?

    init(styleSheet: StyleSheet, isVertical: Bool = true) {
        self.styleSheet = styleSheet
        super.init(frame: .zero)
        self.isVertical = isVertical
        dividerStyle = .thin
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var dividerColor: NSColor { styleSheet.rule }

    override func drawDivider(in rect: NSRect) {
        super.drawDivider(in: rect)
        guard let hoveredBand, hoveredBand.intersects(rect) else { return }
        styleSheet.marker.setFill()
        let grip = gripRect(in: rect)
        let radius = min(grip.width, grip.height) / 2
        NSBezierPath(roundedRect: grip, xRadius: radius, yRadius: radius).fill()
    }

    /// The grip lives inside the divider rect, so it costs no layout, cannot be
    /// clipped, and never shifts the panes on either side of it.
    private func gripRect(in divider: NSRect) -> NSRect {
        if isVertical {
            let height = min(Grip.length, divider.height)
            return NSRect(
                x: divider.minX, y: divider.midY - height / 2,
                width: divider.width, height: height
            )
        }
        let width = min(Grip.length, divider.width)
        return NSRect(
            x: divider.midX - width / 2, y: divider.minY,
            width: width, height: divider.height
        )
    }

    /// The gaps between live panes.  Derived rather than cached because a drag
    /// moves them continuously, and `min`/`max` keeps it correct whichever way
    /// the coordinate system runs.
    private var dividerBands: [NSRect] {
        let panes = arrangedSubviews.filter { !isSubviewCollapsed($0) }
        guard panes.count > 1 else { return [] }
        return zip(panes, panes.dropFirst()).map { lead, follow in
            if isVertical {
                let start = min(lead.frame.maxX, follow.frame.minX)
                let end = max(lead.frame.maxX, follow.frame.minX)
                return NSRect(
                    x: start, y: bounds.minY,
                    width: max(dividerThickness, end - start), height: bounds.height
                )
            }
            let start = min(lead.frame.maxY, follow.frame.minY)
            let end = max(lead.frame.maxY, follow.frame.minY)
            return NSRect(
                x: bounds.minX, y: start,
                width: bounds.width, height: max(dividerThickness, end - start)
            )
        }
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Remove only our own: `NSSplitView` installs areas of its own for the
        // divider cursor, and clearing the lot takes the resize cursor with it.
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateHover(at: nil)
    }

    private func updateHover(at point: NSPoint?) {
        let band = point.flatMap { location in
            dividerBands.first {
                $0.insetBy(
                    dx: isVertical ? -Grip.slop : 0,
                    dy: isVertical ? 0 : -Grip.slop
                ).contains(location)
            }
        }
        // Redrawing on every pointer sample would repaint the seam continuously
        // while someone is only reading; only a change of state is worth a pass.
        guard band != hoveredBand else { return }
        hoveredBand = band
        needsDisplay = true
    }
}
