import AppKit
import SwiftMath

/// LaTeX → image, via SwiftMath's pure Core Text typesetter.
///
/// §3.3 rules out a WebView anywhere, and this is the reason it is affordable
/// to: SwiftMath fits inside the Quick Look extension's memory budget where
/// KaTeX in a `WKWebView` does not.
///
/// The single cached path — fragments, HTML export, and PDF export all come
/// through here, so a formula is typeset once per (source, style) pair no
/// matter who asks for it.
public enum MathRenderer {

    /// Typeset LaTeX to an image.  `display` selects display vs inline style.
    ///
    /// `pointSize` should come from `StyleSheet.mathPointSize`, which is the
    /// body font measured against its x-height rather than its raw point size.
    /// §11.3: most apps render formulas visibly too large next to their body
    /// text because they pass the point size straight through.
    public static func image(
        latex: String,
        display: Bool,
        pointSize: CGFloat,
        color: NSColor,
        padding: CGFloat = 0
    ) -> NSImage? {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = MathRendererCacheKey(
            source: trimmed,
            display: display,
            pointSize: (pointSize * 4).rounded() / 4,
            colorToken: colorToken(color),
            padding: (padding * 2).rounded())
        return MarkdownFragmentImageCaches.math.image(for: key, keyCost: key.source.utf8.count) {
            let renderer = MTMathImage(
                latex: trimmed,
                fontSize: key.pointSize,
                textColor: color,
                labelMode: display ? .display : .text,
                textAlignment: display ? .center : .left)
            let (error, image) = renderer.asImage()
            // A malformed formula is agent output, not a crash: it falls back
            // to its source text in the fragment.
            guard error == nil, let image, image.size.width > 0, image.size.height > 0 else {
                return nil
            }
            guard padding > 0 else { return image }
            // SwiftMath crops its bitmap tightly to the glyph bounds, so a
            // formula can sit flush against (or past) its own frame.  The
            // block fragment asks for 8pt of air on every edge; without it a
            // tall integral or fraction clips through the top of the line box.
            let size = NSSize(
                width: image.size.width + padding * 2,
                height: image.size.height + padding * 2)
            let padded = NSImage(size: size)
            padded.lockFocus()
            image.draw(in: NSRect(x: padding, y: padding, width: image.size.width,
                                  height: image.size.height))
            padded.unlockFocus()
            return padded
        }
    }

    private static func colorToken(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return String(format: "%.3f,%.3f,%.3f,%.3f",
                      rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
    }
}

