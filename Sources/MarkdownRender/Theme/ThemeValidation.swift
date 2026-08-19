import AppKit

public struct ThemeContrastFailure: Equatable, Sendable {
    public let path: String
    public let ratio: CGFloat
    public let minimum: CGFloat

    public init(path: String, ratio: CGFloat, minimum: CGFloat) {
        self.path = path
        self.ratio = ratio
        self.minimum = minimum
    }
}

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

    /// Essential text roles are checked against the surfaces on which the
    /// renderer actually draws them. Decorative accents and intentionally
    /// faint rail ticks are excluded; failing this list means body content,
    /// links, headings, or code can become unreadable.
    public func semanticContrastFailures(appearance: NSAppearance? = nil) -> [ThemeContrastFailure] {
        let appearance = appearance ?? (self.appearance == .dark
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua))
        guard let appearance else { return [] }
        let resolver = ColorResolver(appearance: appearance)
        let roles: [(String, ThemeColor, ThemeColor, CGFloat)] = [
            ("palette.text", palette.text, palette.background, 4.5),
            ("palette.textSecondary", palette.textSecondary, palette.background, 4.5),
            ("palette.heading", palette.heading, palette.background, 4.5),
            ("palette.link", palette.link, palette.background, 3.0),
            ("palette.textOnCode", palette.text, palette.codeBackground, 4.5),
            ("palette.textOnInlineCode", palette.text, palette.inlineCodeBackground, 4.5),
            ("palette.textOnSelection", palette.text, palette.selection, 4.0),
            // Comments and markers are intentionally quiet chrome, but they
            // still need a measurable floor against their actual surfaces.
            ("code.commentOnCode", code.comment, palette.codeBackground, 2.0),
            ("palette.markerOnBackground", palette.marker, palette.background, 1.5),
            ("palette.calloutNoteOnBackground", palette.calloutNote, palette.background, 2.0),
            ("palette.calloutWarningOnBackground", palette.calloutWarning, palette.background, 2.0),
            ("palette.calloutSuccessOnBackground", palette.calloutSuccess, palette.background, 2.0),
            ("palette.calloutDangerOnBackground", palette.calloutDanger, palette.background, 2.0),
        ] + (palette.calloutImportant.map {
            [("palette.calloutImportantOnBackground", $0, palette.background, CGFloat(2.0))]
        } ?? [])
        return roles.compactMap { path, foreground, background, minimum in
            guard foreground.isValid, background.isValid else { return nil }
            let ratio = ThemeContrast.ratio(
                foreground: resolver.resolve(foreground), background: resolver.resolve(background))
            guard ratio < minimum else { return nil }
            return ThemeContrastFailure(path: path, ratio: ratio, minimum: minimum)
        }
    }

    private static func colors(in subject: Any, prefix: String) -> [(path: String, color: ThemeColor)] {
        Mirror(reflecting: subject).children.compactMap { child in
            guard let color = child.value as? ThemeColor else { return nil }
            return ("\(prefix).\(child.label ?? "?")", color)
        }
    }
}

private enum ThemeContrast {
    static func ratio(foreground: NSColor, background: NSColor) -> CGFloat {
        let foreground = relativeLuminance(foreground)
        let background = relativeLuminance(background)
        let lighter = max(foreground, background)
        let darker = min(foreground, background)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ color: NSColor) -> CGFloat {
        let color = color.usingColorSpace(.sRGB) ?? color
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent)
            + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }
}
