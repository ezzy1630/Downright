import AppKit
import MarkdownCore

/// Images (§11.3): rounded corners, a restrained shadow, alt text as a
/// caption.  Clicking opens a lightbox, which the view posts through the
/// delegate rather than presenting itself — the render package owns no windows.
///
/// Paths resolve against the document's directory, which is only possible
/// because the app is unsandboxed (§3.4).
final class ImageFragment: DownrightFragment {

    override var suppressesText: Bool { true }

    override var overrideHeight: CGFloat? {
        guard isFirstParagraphOfBlock else { return 0 }
        guard let style = styleSheet else { return nil }
        let grid = max(1, style.baselineGrid)
        let picture = displaySize()
        var height = picture.height
        if !caption.isEmpty { height += RenderMetrics.imageCaptionGap + style.lineHeight }
        return RenderMetrics.snap(height + style.lineHeight * 0.5, grid: grid)
    }

    override func drawObject(at point: CGPoint, in cg: CGContext) {
        guard isFirstParagraphOfBlock, let style = styleSheet else { return }
        let picture = displaySize()
        let origin = CGPoint(x: point.x + max(0, (contentWidth - picture.width) / 2), y: point.y)
        let rect = CGRect(origin: origin, size: picture)

        if let image = loadedImage() {
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 2),
                         blur: RenderMetrics.imageShadowRadius,
                         color: NSColor.black.withAlphaComponent(style.increaseContrast ? 0 : 0.18).cgColor)
            cg.fillRect(rect, color: style.background, radius: RenderMetrics.imageCornerRadius)
            cg.restoreGState()
            draw(image: image, in: rect, in: cg, cornerRadius: RenderMetrics.imageCornerRadius)
        } else {
            // §8.4's trust instrument applied to images: a picture the agent
            // says it wrote and did not is visibly absent, not silently blank.
            cg.fillRect(rect, color: style.codeBackground, radius: RenderMetrics.imageCornerRadius)
            let missing = NSAttributedString(string: "Missing image · \(payload.detail)", attributes: [
                .font: style.monoFont(size: style.bodyFont().pointSize * 0.85),
                .foregroundColor: style.pathMissing,
            ])
            cg.drawText(missing, in: rect.insetBy(dx: 12, dy: 10), flipped: true)
        }

        guard !caption.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(string: caption, attributes: [
            .font: style.bodyFont().withSize(style.bodyFont().pointSize * 0.86),
            .foregroundColor: style.textSecondary,
            .paragraphStyle: paragraph,
        ])
        cg.drawText(text, in: CGRect(x: point.x, y: rect.maxY + RenderMetrics.imageCaptionGap,
                                     width: contentWidth, height: style.lineHeight), flipped: true)
    }

    /// Alt text, which the engine parked on `drReference` when it emitted the
    /// fragment.
    private var caption: String {
        guard let storage = context?.storage, payload.sourceRange.location < storage.length else { return "" }
        return storage.attribute(.drReference, at: payload.sourceRange.location, effectiveRange: nil) as? String ?? ""
    }

    private func displaySize() -> CGSize {
        guard let image = loadedImage(), image.size.width > 0 else {
            return CGSize(width: contentWidth, height: 64)
        }
        let natural = image.size
        guard natural.width > contentWidth else { return natural }
        return CGSize(width: contentWidth, height: (natural.height * contentWidth / natural.width).rounded())
    }

    private func loadedImage() -> NSImage? {
        if let cached = payload.cachedImage, payload.cachedThemeToken == imageToken { return cached }
        guard let url = resolvedURL() else { return nil }
        let image = NSImage(contentsOf: url)
        payload.cachedImage = image
        payload.cachedThemeToken = imageToken
        payload.cachedSize = image?.size ?? .zero
        return image
    }

    /// Images do not depend on the theme, so the cache token is a constant —
    /// but it still has to differ from a real revision so a theme change never
    /// looks like a cache hit for something that was never loaded.
    private var imageToken: Int { Int.min + 1 }

    private func resolvedURL() -> URL? {
        let raw = payload.detail
        guard !raw.isEmpty else { return nil }
        if let url = URL(string: raw), url.scheme == "file" { return url }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        if raw.hasPrefix("~") { return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath) }
        guard let base = context?.documentURL?.deletingLastPathComponent() else { return nil }
        return URL(fileURLWithPath: raw, relativeTo: base).standardizedFileURL
    }
}
