import AppKit
import MarkdownRender

extension NSWindow {
    /// Keeps AppKit's system-drawn chrome in step with the theme a window
    /// paints itself with.
    ///
    /// A window that fills itself with `sheet.background` but never declares an
    /// appearance inherits macOS's.  Choosing Paper Light under a dark system
    /// therefore draws dark-mode push buttons and text fields onto cream, and a
    /// button title styled for dark chrome disappears against it.  Any window
    /// that paints a theme colour owes AppKit the matching appearance.
    ///
    /// Following macOS is the exception, for the reason document windows
    /// already encode: the theme pair tracks the system there, so pinning would
    /// sever the native appearance chain even when the theme changes correctly.
    func applyThemeAppearance(for theme: Theme) {
        let wanted: NSAppearance?
        if Preferences.shared.values.followsSystemAppearance {
            wanted = nil
        } else {
            switch theme.appearance {
            case .light: wanted = NSAppearance(named: .aqua)
            case .dark: wanted = NSAppearance(named: .darkAqua)
            case .auto: wanted = nil
            }
        }
        // Callers apply this from `viewDidChangeEffectiveAppearance`, which an
        // assignment here would re-enter.  Settling for the value already in
        // place ends that on the first pass.
        guard wanted?.name != appearance?.name else { return }
        appearance = wanted
    }
}
