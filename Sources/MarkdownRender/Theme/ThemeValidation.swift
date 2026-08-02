import AppKit

// `ThemeColor.resolved()` deliberately falls back to `.labelColor` so a typo in
// a hand-edited theme degrades instead of crashing while the user is mid-edit
// (§11.2 hot reload).  That is the right runtime behaviour and the wrong
// *validation* behaviour — a fallback is indistinguishable from a colour that
// really is `labelColor`.  These helpers make the failure visible.

extension ThemeColor {
    /// `nil` when `raw` is neither a parseable hex literal nor a known
    /// `system:` colour name.
    public func validated() -> NSColor? {
        if raw.hasPrefix("system:") {
            return NSColor.systemColorNamed(String(raw.dropFirst("system:".count)))
        }
        return NSColor(hexString: raw)
    }

    public var isValid: Bool { validated() != nil }
}

extension Theme {
    /// Every `ThemeColor` in the theme with the path it was found at.
    ///
    /// Found reflectively on purpose: a colour added to `ThemePalette` or
    /// `CodeTheme` later is covered by validation the moment it exists, with no
    /// second list to keep in sync.
    public func allColors() -> [(path: String, color: ThemeColor)] {
        Theme.colors(in: palette, prefix: "palette") + Theme.colors(in: code, prefix: "code")
    }

    /// Paths of every colour that would silently fall back at runtime.
    public func invalidColorPaths() -> [String] {
        allColors().filter { !$0.color.isValid }.map(\.path)
    }

    private static func colors(in subject: Any, prefix: String) -> [(path: String, color: ThemeColor)] {
        Mirror(reflecting: subject).children.compactMap { child in
            guard let color = child.value as? ThemeColor else { return nil }
            return ("\(prefix).\(child.label ?? "?")", color)
        }
    }
}
