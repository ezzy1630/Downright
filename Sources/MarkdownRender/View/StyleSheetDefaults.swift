import AppKit

extension StyleSheet {
    /// The style a view is born with.
    ///
    /// Hosts summon views with no arguments and assign the real sheet on the
    /// next line, so this only has to be *valid* — reading the current theme
    /// means it is also correct for the frame before that assignment lands, and
    /// it keeps `styleSheet` non-optional so nothing ever has to draw a
    /// "no theme yet" state.
    public static var current: StyleSheet {
        StyleSheet(
            theme: ThemeStore.shared.current,
            appearance: NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        )
    }
}

// Small chrome constants the density gutter needs.  Deliberately not the app's
// `PanelFont`/`PanelAnimation`: the gutter ships inside `MarkdownRender` so the
// Quick Look extension can draw the same rail (§10), and it must not reach back
// into the app target for a font size.
enum GutterChrome {
    static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let bodyFont = NSFont.systemFont(ofSize: 10.5)

    /// Full respect for Reduce Motion (§11.4).
    static func animate(
        reduceMotion: Bool,
        duration: TimeInterval,
        _ body: @escaping (NSAnimationContext) -> Void,
        completion: (() -> Void)? = nil
    ) {
        Motion.run(reduceMotion: reduceMotion, duration: duration, changes: body, completion: completion)
    }
}

extension NSColor {
    /// Alpha that respects Increase Contrast (§11.4): a 12% tick that reads as
    /// a hint at normal contrast has to become visible, not stay decorative.
    public func panelAlpha(_ alpha: CGFloat, increaseContrast: Bool) -> NSColor {
        withAlphaComponent(increaseContrast ? min(1, alpha * 1.8) : alpha)
    }
}
