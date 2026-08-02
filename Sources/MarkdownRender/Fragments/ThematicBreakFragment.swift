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
        let diameter: CGFloat = 3
        let gap: CGFloat = 32
        let centre = point.x + contentWidth / 2
        let y = point.y + height / 2 - diameter / 2
        cg.setFillColor(style.textFaint.cgColor)
        for offset in [-gap, 0, gap] as [CGFloat] {
            cg.fillEllipse(in: CGRect(x: centre + offset - diameter / 2, y: y,
                                      width: diameter, height: diameter))
        }
    }
}
