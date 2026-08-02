import AppKit
import CoreText
import MarkdownCore

/// Resolves a theme plus the current system appearance into ready-to-use
/// `NSColor`s and `NSFont`s.  This is what the decoration engine actually
/// consumes.
///
/// Everything is resolved once, in `init`, and stored.  Two reasons: system
/// colours have to be snapshotted *against a specific appearance* to be
/// meaningful off the main drawing path, and the decorator asks for the same
/// dozen values thousands of times per document.  Consequently, assigning to
/// `theme` or `revision` after construction does not recompute anything —
/// build a new `StyleSheet` instead.  `revision` is what fragment caches
/// compare against (§11.2), so a stale sheet is detectable rather than silent.
public struct StyleSheet {
    public var theme: Theme
    public var revision: Int

    // MARK: Fonts (resolved once)

    private let body: NSFont
    private let headings: [NSFont]
    private let mono: NSFont
    private let emphasis: [NSFont]  // indexed by `emphasisIndex(bold:italic:)`

    // MARK: Metrics

    /// The grid unit every vertical measure is a whole multiple of (§11.1).
    /// Derived from the body line height so it scales with the type, then
    /// rounded to a whole point: structural zoom animates between two layouts,
    /// and fractional grid units make the two disagree by a subpixel per line,
    /// which reads as jitter.
    public let baselineGrid: CGFloat
    public let lineHeight: CGFloat
    /// Mean advance of the body font over a prose sample.  Public because the
    /// measure cap is only meaningful relative to it.
    public let averageCharacterWidth: CGFloat
    /// Measure cap in points, derived from `measureCharacters` and the body
    /// font (§11.1).  Clamped to 68–72 characters whatever the config says.
    public let measureWidth: CGFloat
    /// Point size for math so it sits optically against body text (§11.3).
    public let mathPointSize: CGFloat

    // MARK: Colours

    public var background: NSColor
    public var surface: NSColor
    public var text: NSColor
    public var textSecondary: NSColor
    public var textFaint: NSColor
    public var marker: NSColor
    public var accent: NSColor
    public var link: NSColor
    public var rule: NSColor
    public var codeBackground: NSColor
    public var inlineCodeBackground: NSColor
    public var codeRule: NSColor
    public var railTick: NSColor
    public var railTickCurrent: NSColor
    public var quoteRule: NSColor
    public var pathMissing: NSColor
    public var searchHit: NSColor
    public var searchHitCurrent: NSColor
    public var selection: NSColor

    private let headingColors: [NSColor]
    private let calloutColors: [NSColor]      // note, warning, success, danger
    private let changeColors: [NSColor]       // added, removed, modified
    private let codeColors: [SyntaxToken: NSColor]

    // MARK: Accessibility (§11.4)

    public let reduceMotion: Bool
    public let increaseContrast: Bool
    public let reduceTransparency: Bool

    // MARK: - Construction

    public init(theme: Theme, appearance: NSAppearance) {
        self.theme = theme
        self.revision = ThemeStore.shared.revision

        let workspace = NSWorkspace.shared
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency

        let typography = theme.typography

        // Fonts.  Built through locals so nothing reads a property that is
        // still being initialised.
        let bodyFont = StyleSheet.systemFont(
            preset: typography.preset, size: typography.bodySize, weight: .regular
        )
        body = bodyFont
        headings = (1...6).map { level in
            StyleSheet.systemFont(
                preset: typography.preset,
                size: StyleSheet.headingSize(level: level, typography: typography),
                weight: level <= 3 ? .bold : .semibold
            )
        }
        mono = StyleSheet.monoFont(
            family: typography.monoFamily,
            size: typography.bodySize * typography.monoSizeAdjust,
            ligatures: typography.monoLigatures
        )
        emphasis = [
            bodyFont,
            StyleSheet.applying(bold: true, italic: false, to: bodyFont),
            StyleSheet.applying(bold: false, italic: true, to: bodyFont),
            StyleSheet.applying(bold: true, italic: true, to: bodyFont),
        ]

        // Metrics
        let idealLineHeight = typography.bodySize * typography.lineHeightMultiple
        let grid = max(2, (idealLineHeight / 4).rounded())
        baselineGrid = grid
        lineHeight = grid * 4
        let advance = StyleSheet.averageCharacterWidth(of: bodyFont)
        averageCharacterWidth = advance
        measureWidth = advance * min(72, max(68, typography.measureCharacters))
        mathPointSize = StyleSheet.mathPointSize(body: bodyFont, typography: typography)

        // Colours
        let palette = theme.palette
        let resolver = ColorResolver(appearance: appearance)
        let resolvedText = resolver.resolve(palette.text)
        let boost = increaseContrast

        background = resolver.resolve(palette.background)
        surface = resolver.resolve(palette.surface)
        text = resolvedText
        textSecondary = resolver.resolve(palette.textSecondary, towards: resolvedText, if: boost)
        textFaint = resolver.resolve(palette.textFaint, towards: resolvedText, if: boost)
        marker = resolver.resolve(palette.marker, towards: resolvedText, if: boost)
        accent = resolver.resolve(palette.accent)
        link = resolver.resolve(palette.link)
        rule = resolver.resolve(palette.rule, towards: resolvedText, if: boost)
        codeBackground = resolver.resolve(palette.codeBackground)
        inlineCodeBackground = resolver.resolve(palette.inlineCodeBackground)
        codeRule = resolver.resolve(palette.codeRule, towards: resolvedText, if: boost)
        railTick = resolver.resolve(palette.railTick, towards: resolvedText, if: boost)
        railTickCurrent = resolver.resolve(palette.railTickCurrent, towards: resolvedText, if: boost)
        quoteRule = resolver.resolve(palette.quoteRule, towards: resolvedText, if: boost)
        pathMissing = resolver.resolve(palette.pathMissing)
        searchHit = resolver.resolve(palette.searchHit)
        searchHitCurrent = resolver.resolve(palette.searchHitCurrent)
        selection = resolver.resolve(palette.selection)

        // H1–H3 carry the heading colour; H4–H6 fade toward secondary text.  A
        // sixth-level heading that shouts as loudly as the title is the reason
        // deep documents read as noise.
        let headingBase = resolver.resolve(palette.heading)
        headingColors = (1...6).map { level in
            guard level > 3 else { return headingBase }
            return ColorResolver.blend(headingBase, resolver.resolve(palette.textSecondary), CGFloat(level - 3) / 4)
        }
        calloutColors = [
            resolver.resolve(palette.calloutNote),
            resolver.resolve(palette.calloutWarning),
            resolver.resolve(palette.calloutSuccess),
            resolver.resolve(palette.calloutDanger),
        ]
        changeColors = [
            resolver.resolve(palette.changeAdded),
            resolver.resolve(palette.changeRemoved),
            resolver.resolve(palette.changeModified),
        ]
        codeColors = StyleSheet.codeColors(theme.code, text: resolvedText, resolver: resolver)
    }

    // MARK: - Fonts

    public func bodyFont() -> NSFont { body }

    public func headingFont(level: Int) -> NSFont { headings[StyleSheet.clampLevel(level) - 1] }

    public func monoFont(size: CGFloat? = nil) -> NSFont {
        guard let size, size != mono.pointSize else { return mono }
        return NSFont(descriptor: mono.fontDescriptor, size: size) ?? mono
    }

    /// Attributes rather than just a font, because a ligature *toggle* is not
    /// purely a font property: `NSAttributedString.Key.ligature` is what
    /// actually suppresses them at layout time, and the font feature settings
    /// are what suppress the programming ligatures (`calt`) that faces like
    /// Fira Code deliver outside the standard ligature feature.
    public func monoFontAttributes(size: CGFloat? = nil) -> [NSAttributedString.Key: Any] {
        [.font: monoFont(size: size), .ligature: theme.typography.monoLigatures ? 1 : 0]
    }

    public func emphasisFont(bold: Bool, italic: Bool) -> NSFont {
        emphasis[(bold ? 1 : 0) + (italic ? 2 : 0)]
    }

    /// Whole steps of the modular scale for H1–H4, half steps below the body
    /// size for H5–H6.  A pure power law would put H6 at `body · ratio⁻²` —
    /// 10pt against a 16pt body — which is unreadable; half steps keep the six
    /// levels strictly ordered without dropping off a cliff (§11.1).
    private static let headingExponents: [CGFloat] = [3, 2, 1.25, 0.5, 0, 0]

    static func headingSize(level: Int, typography: TypographyConfig) -> CGFloat {
        let exponent = headingExponents[clampLevel(level) - 1]
        return typography.bodySize * pow(typography.scaleRatio, exponent)
    }

    /// Vertical rhythm in whole grid units, so a heading never knocks the body
    /// text off the baseline grid (§11.1).
    public func headingSpacing(level: Int) -> (before: CGFloat, after: CGFloat) {
        let before: [CGFloat] = [4, 5, 4, 3, 2, 2]
        let after: [CGFloat] = [2, 2, 2, 1, 1, 1]
        let index = StyleSheet.clampLevel(level) - 1
        return (before[index] * baselineGrid, after[index] * baselineGrid)
    }

    private static func clampLevel(_ level: Int) -> Int { min(6, max(1, level)) }

    private static func systemFont(preset: TypographyConfig.BodyPreset, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard preset == .reading else { return base }  // Working = SF Pro Text
        // Reading = New York, reached through the descriptor's serif design
        // rather than by family name, so it tracks whatever Apple ships.
        guard let descriptor = base.fontDescriptor.withDesign(.serif),
              let serif = NSFont(descriptor: descriptor, size: size)
        else { return base }
        return serif
    }

    private static func monoFont(family: String, size: CGFloat, ligatures: Bool) -> NSFont {
        // SF Mono is not installed on every machine and is not exposed under a
        // single stable name, so the chain degrades: configured face, SF Mono
        // under both of its names, Menlo, then the system monospace face.
        let candidates = [family, "SF Mono", "SFMono-Regular", "Menlo"]
        var resolved: NSFont?
        for name in candidates where !name.isEmpty {
            if let font = NSFont(name: name, size: size) { resolved = font; break }
        }
        let font = resolved ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return applyingLigatures(ligatures, to: font)
    }

    private static func applyingLigatures(_ enabled: Bool, to font: NSFont) -> NSFont {
        guard !enabled else { return font }
        let settings: [[NSFontDescriptor.FeatureKey: Int]] = [
            [.typeIdentifier: Int(kLigaturesType), .selectorIdentifier: Int(kCommonLigaturesOffSelector)],
            [.typeIdentifier: Int(kLigaturesType), .selectorIdentifier: Int(kRareLigaturesOffSelector)],
            [.typeIdentifier: Int(kContextualAlternatesType), .selectorIdentifier: Int(kContextualAlternatesOffSelector)],
        ]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: settings])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private static func applying(bold: Bool, italic: Bool, to font: NSFont) -> NSFont {
        guard bold || italic else { return font }
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// The mean advance over a prose sample.  The usual shortcut — the advance
    /// of `0` — over-estimates badly for a proportional face, which is exactly
    /// how measure caps end up 20% too wide (§11.1).
    private static func averageCharacterWidth(of font: NSFont) -> CGFloat {
        let sample = Array("the quick brown fox jumps over the lazy dog, and then it did it again. ".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: sample.count)
        guard CTFontGetGlyphsForCharacters(font as CTFont, sample, &glyphs, sample.count) else {
            return font.pointSize * 0.5
        }
        var advances = [CGSize](repeating: .zero, count: sample.count)
        CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, glyphs, &advances, sample.count)
        let total = advances.reduce(CGFloat(0)) { $0 + $1.width }
        return total > 0 ? total / CGFloat(sample.count) : font.pointSize * 0.5
    }

    /// Latin Modern Math — SwiftMath's default face — has an x-height of 0.431
    /// em.  Matching x-heights rather than point sizes is what stops formulas
    /// sitting visibly large next to the prose (§11.3).  The result is clamped
    /// to 0.90–1.10× the body size so an unusual body face cannot push math out
    /// of the band where it still reads as the same size.
    private static let mathFontXHeightRatio: CGFloat = 0.431

    private static func mathPointSize(body: NSFont, typography: TypographyConfig) -> CGFloat {
        let optical = body.xHeight / mathFontXHeightRatio
        let clamped = min(max(optical, typography.bodySize * 0.90), typography.bodySize * 1.10)
        return clamped * typography.mathScale
    }

    // MARK: - Colours

    public func headingColor(level: Int) -> NSColor { headingColors[StyleSheet.clampLevel(level) - 1] }

    /// Fourteen callout kinds share four palette slots, grouped by what the
    /// reader is meant to *do*: absorb, act carefully, confirm, or stop.
    public func calloutColor(_ kind: CalloutKind) -> NSColor {
        switch kind {
        case .note, .info, .abstract, .quote, .example: return calloutColors[0]
        case .warning, .caution, .question, .todo: return calloutColors[1]
        case .tip, .success: return calloutColors[2]
        case .important, .danger, .bug: return calloutColors[3]
        }
    }

    public func calloutSymbol(_ kind: CalloutKind) -> String {
        switch kind {
        case .note: return "note.text"
        case .tip: return "lightbulb"
        case .important: return "exclamationmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .caution: return "hand.raised"
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .question: return "questionmark.circle"
        case .danger: return "exclamationmark.octagon"
        case .example: return "list.bullet.rectangle"
        case .quote: return "quote.opening"
        case .abstract: return "doc.text"
        case .bug: return "ladybug"
        case .todo: return "checklist"
        }
    }

    public func changeColor(_ kind: ChangeKind) -> NSColor {
        switch kind {
        case .inserted: return changeColors[0]
        case .deleted: return changeColors[1]
        case .modified: return changeColors[2]
        }
    }

    public func codeColor(_ token: SyntaxToken) -> NSColor { codeColors[token] ?? text }

    private static func codeColors(
        _ code: CodeTheme, text: NSColor, resolver: ColorResolver
    ) -> [SyntaxToken: NSColor] {
        [
            .plain: text,
            .keyword: resolver.resolve(code.keyword),
            .string: resolver.resolve(code.string),
            .number: resolver.resolve(code.number),
            .comment: resolver.resolve(code.comment),
            .type: resolver.resolve(code.type),
            .function: resolver.resolve(code.function),
            .variable: resolver.resolve(code.variable),
            .constant: resolver.resolve(code.constant),
            .operator: resolver.resolve(code.operator),
            .punctuation: resolver.resolve(code.punctuation),
            .attribute: resolver.resolve(code.attribute),
            .diffAdded: resolver.resolve(code.diffAdded),
            .diffRemoved: resolver.resolve(code.diffRemoved),
            .diffHeader: resolver.resolve(code.diffHeader),
        ]
    }
}

// MARK: - Colour resolution

/// Turns a `ThemeColor` into a concrete colour for one appearance.
///
/// System colours are dynamic catalogue colours; reading their components
/// without a current appearance gives whatever the process last drew in.
/// Snapshotting them here is what lets a `StyleSheet` be built off the drawing
/// path and still be right (§11.2).
struct ColorResolver {
    let appearance: NSAppearance

    func resolve(_ themeColor: ThemeColor) -> NSColor {
        ColorResolver.snapshot(themeColor.resolved(), in: appearance)
    }

    /// Increase Contrast (§11.4) is applied only to the *quiet* colours —
    /// secondary text, faint text, rules, markers — by pulling each a third of
    /// the way toward the primary text colour.  Re-tinting the whole theme
    /// would destroy a designed palette to solve a problem it does not have.
    func resolve(_ themeColor: ThemeColor, towards target: NSColor, if enabled: Bool) -> NSColor {
        let base = resolve(themeColor)
        guard enabled else { return base }
        return ColorResolver.blend(base, target, 1.0 / 3.0)
    }

    private static func snapshot(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    static func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        guard let lhs = a.usingColorSpace(.sRGB), let rhs = b.usingColorSpace(.sRGB) else { return a }
        let mix = min(max(t, 0), 1)
        return NSColor(
            srgbRed: lhs.redComponent + (rhs.redComponent - lhs.redComponent) * mix,
            green: lhs.greenComponent + (rhs.greenComponent - lhs.greenComponent) * mix,
            blue: lhs.blueComponent + (rhs.blueComponent - lhs.blueComponent) * mix,
            alpha: lhs.alphaComponent + (rhs.alphaComponent - lhs.alphaComponent) * mix
        )
    }
}
