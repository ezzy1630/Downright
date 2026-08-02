import AppKit
import MarkdownCore

/// Block math (§11.3), typeset by SwiftMath and **sized optically against body
/// text**: the point size handed to the renderer is `styleSheet.mathPointSize`,
/// which is the body font measured by its x-height, not its raw point size.
/// Passing the raw point size is why most apps render formulas visibly too
/// large next to their prose, and it is one of the differences you notice
/// immediately.
///
/// The typeset image is cached on the `FragmentPayload` and invalidated on
/// `styleSheet.revision`, so a theme change re-renders and nothing else does.
final class MathFragment: DownrightFragment {

    override var suppressesText: Bool { true }

    override var overrideHeight: CGFloat? {
        guard isFirstParagraphOfBlock else { return 0 }
        guard let style = styleSheet else { return nil }
        let size = renderedImage()?.size ?? CGSize(width: 0, height: style.lineHeight)
        return RenderMetrics.snap(size.height + style.lineHeight * 0.7, grid: max(1, style.baselineGrid))
    }

    override func drawObject(at point: CGPoint, in cg: CGContext) {
        guard isFirstParagraphOfBlock, let style = styleSheet else { return }
        guard let image = renderedImage() else {
            drawFallback(at: point, in: cg, style: style)
            return
        }
        let frame = layoutFragmentFrame
        let origin = CGPoint(
            x: point.x + max(0, (contentWidth - image.size.width) / 2),
            y: point.y + max(0, (frame.height - image.size.height) / 2))
        draw(image: image, at: origin, in: cg)
    }

    /// A formula that will not typeset is agent output, not an error state:
    /// it falls back to its own source, dimmed, so you can see what broke.
    private func drawFallback(at point: CGPoint, in cg: CGContext, style: StyleSheet) {
        let text = NSAttributedString(string: payload.detail, attributes: [
            .font: style.monoFont(size: style.bodyFont().pointSize * 0.9),
            .foregroundColor: style.textFaint,
        ])
        cg.drawText(text, in: CGRect(x: point.x, y: point.y + 2, width: contentWidth,
                                     height: layoutFragmentFrame.height), flipped: true)
    }

    private func renderedImage() -> NSImage? {
        guard let style = styleSheet else { return nil }
        if let cached = payload.cachedImage, payload.cachedThemeToken == styleToken { return cached }
        let image = MathRenderer.image(latex: payload.detail, display: true,
                                       pointSize: style.mathPointSize * 1.25, color: style.text)
        payload.cachedImage = image
        payload.cachedThemeToken = styleToken
        payload.cachedSize = image?.size ?? .zero
        return image
    }
}

extension DownrightFragment {
    /// Draws an `NSImage` into a flipped CGContext without going through
    /// AppKit's focus stack, which is not valid inside a layout fragment.
    func draw(image: NSImage, in target: CGRect, in cg: CGContext, cornerRadius: CGFloat = 0) {
        var proposed = target
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return }
        cg.saveGState()
        if cornerRadius > 0 {
            cg.addPath(CGPath(roundedRect: target, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
            cg.clip()
        }
        cg.translateBy(x: 0, y: target.midY)
        cg.scaleBy(x: 1, y: -1)
        cg.translateBy(x: 0, y: -target.midY)
        cg.draw(cgImage, in: target)
        cg.restoreGState()
    }

    func draw(image: NSImage, at origin: CGPoint, in cg: CGContext) {
        draw(image: image, in: CGRect(origin: origin, size: image.size), in: cg)
    }
}
