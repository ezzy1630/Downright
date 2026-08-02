import AppKit
import MarkdownCore

/// Mermaid diagrams (§11.3), rendered natively by `beautiful-mermaid-swift`
/// and themed from the active palette so diagrams and code blocks share one
/// look (§11.2).
///
/// Rendered lazily — the first time the fragment is actually asked to draw,
/// which is the first time it enters the viewport — and held in a shared,
/// cost-bounded cache.  §10's memory discipline depends on this laziness and
/// bounded retention holding in the Quick Look extension too.
final class MermaidFragment: DownrightFragment {

    override var suppressesText: Bool { true }

    override var overrideHeight: CGFloat? {
        guard isFirstParagraphOfBlock else { return 0 }
        guard let style = styleSheet else { return nil }
        let size = renderedSize()
        guard size.height > 0 else { return style.lineHeight * 2 }
        return RenderMetrics.snap(size.height + style.lineHeight, grid: max(1, style.baselineGrid))
    }

    override func drawObject(at point: CGPoint, in cg: CGContext) {
        guard isFirstParagraphOfBlock, let style = styleSheet else { return }
        guard let image = renderedImage() else {
            let text = NSAttributedString(string: payload.detail, attributes: [
                .font: style.monoFont(size: style.bodyFont().pointSize * 0.9),
                .foregroundColor: style.textFaint,
            ])
            cg.drawText(text, in: CGRect(x: point.x, y: point.y, width: contentWidth,
                                         height: layoutFragmentFrame.height), flipped: true)
            return
        }
        let size = renderedSize()
        let origin = CGPoint(x: point.x + max(0, (contentWidth - size.width) / 2),
                             y: point.y + max(0, (layoutFragmentFrame.height - size.height) / 2))
        draw(image: image, in: CGRect(origin: origin, size: size), in: cg)
    }

    /// Point size, not pixel size: the renderer draws at backing scale, so the
    /// image's own `size` is already in points but a wide diagram still has to
    /// be brought inside the measure.
    private func renderedSize() -> CGSize {
        guard let image = renderedImage() else { return .zero }
        let natural = image.size
        guard natural.width > contentWidth, natural.width > 0 else { return natural }
        let scale = contentWidth / natural.width
        return CGSize(width: contentWidth, height: (natural.height * scale).rounded())
    }

    private func renderedImage() -> NSImage? {
        guard let style = styleSheet else { return nil }
        let key = MermaidFragmentCacheKey(
            source: payload.detail.trimmingCharacters(in: .whitespacesAndNewlines),
            styleToken: styleToken)
        return MarkdownFragmentImageCaches.mermaid.image(for: key, keyCost: key.source.utf8.count) {
            MermaidRendererBridge.image(source: key.source, styleSheet: style)
        }
    }
}
