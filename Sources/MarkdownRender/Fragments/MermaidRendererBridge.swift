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
        let key = Key(source: trimmed, revision: StyleToken.of(styleSheet))

        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let renderer = MermaidImageRenderer(theme: theme(from: styleSheet), config: LayoutConfig())
        // A diagram that does not parse is agent output, not a crash: the
        // fragment falls back to the highlighted source.
        let image = (try? renderer.renderImage(from: trimmed, scale: scale())) ?? nil

        lock.lock()
        cache[key] = image
        if cache.count > capacity { cache.removeAll(keepingCapacity: true) }
        lock.unlock()
        return image
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
            lineWidth: styleSheet.increaseContrast ? 2 : 1.5,
            cornerRadius: 8,
            // Composited over the document background, which the fragment
            // already fills; an opaque diagram card would read as a bordered
            // box, and §11.3 wants restraint.
            transparent: true)
    }

    private struct Key: Hashable {
        var source: String
        var revision: Int
    }

    private static let lock = NSLock()
    private static var cache: [Key: NSImage?] = [:]
    private static let capacity = 64

    private static func scale() -> CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }
}
