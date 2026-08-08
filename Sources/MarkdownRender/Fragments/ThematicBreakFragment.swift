import AppKit
import MarkdownCore

/// A horizontal rule as a hairline with generous space (§11.3), not a thick
/// divider.  Most of the element is the air around it: a rule that shouts is a
/// rule you read as a heading.
final class ThematicBreakFragment: DownrightFragment {

    override var suppressesText: Bool { true }

    override var overrideHeight: CGFloat? {
        guard isFirstParagraphOfBlock else { return 0 }
        guard let style = styleSheet else { return nil }
        return RenderMetrics.snap(RenderMetrics.thematicBreakSpace * 2, grid: max(1, style.baselineGrid))
    }

    override func drawObject(at point: CGPoint, in cg: CGContext) {
        guard isFirstParagraphOfBlock, let style = styleSheet else { return }
        let height = layoutFragmentFrame.height
        // Derived from the type ramp, not fixed: at 17pt body these are the
        // original 3pt dots 32pt apart, and they keep that proportion when the
        // reader changes size.  A hardcoded pair reads as three fat blobs at
        // 11pt and as three specks at 28pt.
        let bodySize = style.bodyFont().pointSize
        let diameter = max(2, (bodySize * 0.18).rounded())
        let gap = RenderMetrics.snap(bodySize * 1.9, grid: max(1, style.baselineGrid))
        // Centred on the *reading* column, not the full one: a rule that
        // centred itself over the bleed lane sat visibly right of the prose it
        // divides.
        let centre = point.x + proseContentWidth / 2
        let y = point.y + height / 2 - diameter / 2
        cg.setFillColor(style.textFaint.cgColor)
        for offset in [-gap, 0, gap] as [CGFloat] {
            cg.fillEllipse(in: CGRect(x: centre + offset - diameter / 2, y: y,
                                      width: diameter, height: diameter))
        }
    }
}
