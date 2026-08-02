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
        // A hairline, not a point: on Retina this is a genuine 0.5pt rule.
        let thickness: CGFloat = style.increaseContrast ? 1 : 0.5
        let inset = contentWidth * 0.04
        cg.fillRect(CGRect(x: point.x + inset, y: (point.y + height / 2).rounded(),
                           width: max(1, contentWidth - inset * 2), height: thickness),
                    color: style.rule)
    }
}
