import AppKit
import MarkdownCore

/// Block math (§11.3), typeset by SwiftMath and **sized optically against body
/// text**: the point size handed to the renderer is `styleSheet.mathPointSize`,
/// which is the body font measured by its x-height, not its raw point size.
/// Passing the raw point size is why most apps render formulas visibly too
/// large next to their prose, and it is one of the differences you notice
/// immediately.
///
/// The typeset image is held in a shared, cost-bounded cache keyed by source
/// and resolved style.  Fragments do not retain one image per payload, which
/// keeps long documents from turning relayout into permanent image memory.
final class MathFragment: DownrightFragment {

    override var suppressesText: Bool { true }

    /// A formula that will not typeset is agent output, not an error state —
    /// but silent dimmed source reads as intentional.  Name the failure and
    /// keep the source under it, exactly as a broken diagram does.
    private var failure: FailedObject {
        FailedObject(label: "Formula could not be typeset", source: payload.detail)
    }

    override var overrideHeight: CGFloat? {
        guard isFirstParagraphOfBlock else { return 0 }
        guard let style = styleSheet else { return nil }
        let grid = max(1, style.baselineGrid)
        guard let image = renderedImage() else {
            return RenderMetrics.snap(
                failedObjectHeight(failure, style: style) + style.lineHeight * 0.5, grid: grid)
        }
        return RenderMetrics.snap(image.size.height + style.lineHeight * 0.7, grid: grid)
    }

    override func drawObject(at point: CGPoint, in cg: CGContext) {
        guard isFirstParagraphOfBlock, let style = styleSheet else { return }
        guard let image = renderedImage() else {
            drawFailedObject(
                failure,
                in: CGRect(x: point.x, y: point.y, width: contentWidth,
                           height: failedObjectHeight(failure, style: style)),
                style: style,
                in: cg
            )
            return
        }
        let frame = layoutFragmentFrame
        let origin = CGPoint(
            x: point.x + max(0, (contentWidth - image.size.width) / 2),
            y: point.y + max(0, (frame.height - image.size.height) / 2))
        draw(image: image, at: origin, in: cg)
    }

    private func renderedImage() -> NSImage? {
        guard let style = styleSheet else { return nil }
        let pointSize = style.mathPointSize * 1.25
        // SwiftMath crops tightly to the glyph bounds; the padded bitmap keeps
        // ≥ 8pt of air on every edge so a tall formula never clips through its
        // own line box (§11.3).
        return MathRenderer.image(latex: payload.detail, display: true,
                                  pointSize: pointSize, color: style.text, padding: 8)
    }
}

extension DownrightFragment {
    /// Draws an `NSImage` into a flipped CGContext without going through
    /// AppKit's focus stack, which is not valid inside a layout fragment.
    func draw(image: NSImage, in target: CGRect, in cg: CGContext, cornerRadius: CGFloat = 0) {
        drawNSImage(image, in: target, in: cg, cornerRadius: cornerRadius)
    }

    func draw(image: NSImage, at origin: CGPoint, in cg: CGContext) {
        draw(image: image, in: CGRect(origin: origin, size: image.size), in: cg)
    }
}
