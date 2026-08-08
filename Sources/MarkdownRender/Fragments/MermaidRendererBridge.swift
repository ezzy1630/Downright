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
    /// sequence, then crops the result to the pixels the diagram actually
    /// inked.
    ///
    /// The crop is the point of this function.  `prepared.bounds` is the
    /// layout's own idea of its extent, and for several diagram kinds — a
    /// sequence diagram above all — that is materially taller and wider than
    /// anything drawn: reserved lifeline runway, room for labels that turned
    /// out to be short.  Sizing the fragment from it left a band of dead space
    /// under every diagram that read as a layout bug, and no amount of tuning
    /// the fragment's own padding could fix it because the emptiness was
    /// *inside the image*.  Rendering with slack and then measuring the alpha
    /// channel makes the returned size mean "this is how big the drawing is",
    /// which is the only size the fragment can lay out honestly.
    ///
    /// Air around the diagram is deliberately *not* baked in here — the
    /// fragment adds it, so one place decides the spacing.
    private static func render(_ prepared: PreparedDiagram, scale: CGFloat) -> NSImage? {
        let bounds = prepared.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // Slack only so a stroke, shadow, or overshooting label near the edge
        // is not clipped before it can be measured; the crop takes it back.
        let slack: CGFloat = 32
        let padded = bounds.insetBy(dx: -slack, dy: -slack)
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

        guard let ink = inkBounds(of: ctx), let cropped = cgImage.cropping(to: ink) else {
            return NSImage(cgImage: cgImage, size: padded.size)
        }
        return NSImage(cgImage: cropped,
                       size: CGSize(width: CGFloat(cropped.width) / scale,
                                    height: CGFloat(cropped.height) / scale))
    }

    /// The smallest pixel rect containing every non-transparent pixel, in the
    /// image coordinates `CGImage.cropping(to:)` expects, or nil if the bitmap
    /// is entirely empty.
    ///
    /// The theme renders `transparent: true`, so "inked" is exactly "alpha
    /// above the noise floor".  The threshold is not zero: antialiasing leaves
    /// a halo one or two units above nothing at all, and treating that as ink
    /// would grow the crop back toward the untrimmed bounds.
    private static func inkBounds(of ctx: CGContext) -> CGRect? {
        guard let base = ctx.data, ctx.bitsPerComponent == 8 else { return nil }
        let width = ctx.width
        let height = ctx.height
        let stride = ctx.bytesPerRow
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let alphaFloor: UInt8 = 8

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = pixels + y * stride
            var rowMinX = -1
            var rowMaxX = -1
            for x in 0..<width where row[x * 4 + 3] > alphaFloor {
                if rowMinX < 0 { rowMinX = x }
                rowMaxX = x
            }
            guard rowMinX >= 0 else { continue }
            minX = min(minX, rowMinX)
            maxX = max(maxX, rowMaxX)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
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
