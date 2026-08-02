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
    public static func image(latex: String, display: Bool, pointSize: CGFloat, color: NSColor) -> NSImage? {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = Key(latex: trimmed, display: display,
                      pointSize: (pointSize * 4).rounded() / 4,
                      color: colorToken(color))

        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit.image
        }
        lock.unlock()

        let renderer = MTMathImage(
            latex: trimmed,
            fontSize: key.pointSize,
            textColor: color,
            labelMode: display ? .display : .text,
            textAlignment: display ? .center : .left)
        let (error, image) = renderer.asImage()
        // A malformed formula is agent output, not a crash: it falls back to
        // its source text in the fragment.
        let result = error == nil ? image : nil

        lock.lock()
        cache[key] = Entry(image: result)
        if cache.count > capacity { evictLocked() }
        lock.unlock()
        return result
    }

    // MARK: Cache

    private struct Key: Hashable {
        var latex: String
        var display: Bool
        var pointSize: CGFloat
        var color: String
    }

    private struct Entry {
        var image: NSImage?
    }

    private static let lock = NSLock()
    private static var cache: [Key: Entry] = [:]
    private static let capacity = 512

    private static func evictLocked() {
        // Formula caches are small and long-lived; a full clear at the cap is
        // cheaper and more predictable than tracking recency per entry.
        cache.removeAll(keepingCapacity: true)
    }

    private static func colorToken(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return String(format: "%.3f,%.3f,%.3f,%.3f",
                      rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
    }
}
