import AppKit
import BeautifulMermaid

/// Mermaid → image, native (§3.3), themed from the active `StyleSheet`.
///
/// §11.2 wants code blocks and diagrams to share one palette; that consistency
/// is rare and immediately noticeable, and it comes for free by deriving the
/// `DiagramTheme` from the same stylesheet the code fragments read.
///
/// The single cached path — fragments and export both come through here.
public enum MermaidRendererBridge {

    /// Render mermaid source, themed from the active `StyleSheet`.
    public static func image(source: String, styleSheet: StyleSheet) -> NSImage? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let scale = scale()
        let key = MermaidCacheKey(
            source: trimmed,
            styleToken: StyleToken.of(styleSheet),
            scale: Int((scale * 2).rounded()))

        return MarkdownFragmentImageCaches.mermaid.image(for: key, keyCost: key.source.utf8.count) {
            // Render via `prepare(from:)` into our own bitmap context rather than
            // through `renderImage(from:scale:)`.  The latter's AppKit branch
            // (`_renderPrepared`) draws the diagram into a raw CGContext without
            // flipping it to y=0-at-top first, which mirrors the shapes while
            // `LabelRenderer` locally re-flips the text — the exact split that
            // renders node labels upside down (§11.3).  `MermaidLayer`'s AppKit
            // path flips the context before rendering; we replicate that here
            // so shapes and labels agree on one coordinate system.
            let renderer = MermaidImageRenderer(theme: theme(from: styleSheet), config: LayoutConfig())
            guard let prepared = try? renderer.prepare(from: trimmed) else { return nil }
            return render(prepared, scale: scale)
        }
    }

    /// Draws a prepared diagram into a bitmap context that has been flipped to
    /// y=0-at-top, matching `MermaidLayer.renderImage`'s AppKit transform
    /// sequence.  The returned image's point size is the diagram bounds plus
    /// 24pt of air on every side (pixels are `scale`×), which is what the
    /// fragment expects — the diagram fills its frame without clipping and
    /// without dead margins.
    private static func render(_ prepared: PreparedDiagram, scale: CGFloat) -> NSImage? {
        let bounds = prepared.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let air: CGFloat = 24
        let padded = bounds.insetBy(dx: -air, dy: -air)
        let pixelWidth = Int((padded.width * scale).rounded())
        let pixelHeight = Int((padded.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              let ctx = CGContext(
                  data: nil, width: pixelWidth, height: pixelHeight,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(pixelHeight))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -padded.minX, y: -padded.minY)
        prepared.render(ctx, bounds)
        guard let cgImage = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: padded.size)
    }

    /// The stylesheet's palette expressed as a diagram theme.  Exposed so the
    /// HTML/PDF export path can render diagrams identically without
    /// reconstructing the mapping.
    public static func theme(from styleSheet: StyleSheet) -> DiagramTheme {
        DiagramTheme(
            background: styleSheet.background,
            foreground: styleSheet.text,
            line: styleSheet.rule,
            accent: styleSheet.accent,
            muted: styleSheet.textSecondary,
            surface: styleSheet.codeBackground,
            border: styleSheet.codeRule,
            font: styleSheet.bodyFont(),
            lineWidth: styleSheet.increaseContrast ? 2.25 : 1.75,
            cornerRadius: 8,
            // Composited over the document background, which the fragment
            // already fills; an opaque diagram card would read as a bordered
            // box, and §11.3 wants restraint.
            transparent: true)
    }

    private static func scale() -> CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }
}
