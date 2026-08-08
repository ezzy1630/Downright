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
        // Images sit in the reading column, so they centre on it — centring on
        // the full column would push every picture into the right bleed lane.
        let origin = CGPoint(x: point.x + max(0, (proseContentWidth - picture.width) / 2), y: point.y)
        let rect = CGRect(origin: origin, size: picture)

        if let image = loadedImage() {
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 2),
                         blur: RenderMetrics.imageShadowRadius,
                         color: NSColor.black.withAlphaComponent(style.increaseContrast ? 0 : 0.18).cgColor)
            cg.fillRect(rect, color: matte(for: image, style: style),
                        radius: RenderMetrics.imageCornerRadius)
            cg.restoreGState()
            draw(image: image, in: rect, in: cg, cornerRadius: RenderMetrics.imageCornerRadius)
            if style.theme.appearance == .dark {
                cg.setStrokeColor(style.text.withAlphaComponent(0.08).cgColor)
                cg.setLineWidth(1)
                cg.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            }
        } else {
            // §8.4's trust instrument applied to images: a picture the agent
            // says it wrote and did not is visibly absent, not silently blank.
            drawFailedObject(missing, in: rect, style: style, in: cg)
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
                                     width: proseContentWidth, height: style.lineHeight), flipped: true)
    }

    /// Alt text, which the engine parked on `drReference` when it emitted the
    /// fragment.
    private var caption: String {
        guard let storage = context?.storage, payload.sourceRange.location < storage.length else { return "" }
        return storage.attribute(.drReference, at: payload.sourceRange.location, effectiveRange: nil) as? String ?? ""
    }

    /// The placeholder for a file that is not there.  The path is the whole
    /// message, so it lives in the mono line and wraps; a fixed 64pt box just
    /// clipped anything longer than the measure.
    private var missing: FailedObject {
        FailedObject(label: "Missing image", source: payload.detail)
    }

    /// What the image is composited over.
    ///
    /// Transparent line art is usually black ink, so compositing it on the page
    /// makes it disappear in a dark theme.  DESIGN rules out auto-inverting the
    /// artwork, so it gets a plate instead: the lighter of the theme's two
    /// poles — the page itself in a light theme, a warm near-white in a dark
    /// one.  An opaque image covers the plate entirely, so this costs nothing
    /// when there is no alpha to matte.
    private func matte(for image: NSImage, style: StyleSheet) -> NSColor {
        guard image.representations.first?.hasAlpha == true else { return style.background }
        let page = style.background
        let ink = style.text
        guard Self.brightness(of: ink) > Self.brightness(of: page) else { return page }
        return ink.mixed(with: page, amount: 0.06)
    }

    private static func brightness(of color: NSColor) -> CGFloat {
        (color.usingColorSpace(.sRGB) ?? color).brightnessComponent
    }

    private func displaySize() -> CGSize {
        guard let image = loadedImage(), image.size.width > 0 else {
            guard let style = styleSheet else { return CGSize(width: proseContentWidth, height: 64) }
            return CGSize(width: proseContentWidth,
                          height: failedObjectHeight(missing, style: style))
        }
        let natural = image.size
        let viewportCap = viewportHeightCap
        let widthScale = min(1, proseContentWidth / natural.width)
        let heightScale = min(1, viewportCap / natural.height)
        let scale = min(widthScale, heightScale)
        return CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
    }

    private func loadedImage() -> NSImage? {
        guard let url = resolvedURL() else { return nil }
        return MarkdownFragmentImageCaches.images.image(
            for: url, maxPixelDimension: targetPixelDimension)
    }

    private var viewportHeightCap: CGFloat {
        max(120, (context?.textView?.enclosingScrollView?.contentSize.height ?? 800) * 0.70)
    }

    private var targetPixelDimension: Int {
        let scale = context?.textView?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        // A hard per-image ceiling prevents one pathological asset from
        // defeating the cache's total budget before it can be evicted.
        let points = max(contentWidth, viewportHeightCap)
        return min(2048, max(1, Int(ceil(points * scale))))
    }

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
