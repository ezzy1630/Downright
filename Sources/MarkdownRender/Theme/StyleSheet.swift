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
    /// The concrete appearance used to snapshot every dynamic colour below.
    /// Detached child windows do not inherit their document window's
    /// appearance reliably, so chrome such as the density preview needs this
    /// same value to resolve native drawing and controls consistently.
    public let appearance: NSAppearance

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

    public init(
        theme: Theme,
        appearance: NSAppearance,
        reduceMotionOverride: Bool? = nil
    ) {
        self.theme = theme
        self.revision = ThemeStore.shared.revision
        self.appearance = appearance

        let workspace = NSWorkspace.shared
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
            || reduceMotionOverride == true
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
            let weight: NSFont.Weight = level <= 3
                ? .bold
                : (level == 6 ? .medium : .semibold)
            let font = StyleSheet.systemFont(
                preset: typography.preset,
                size: StyleSheet.headingSize(level: level, typography: typography),
                weight: weight
            )
            return level == 6 ? StyleSheet.applying(bold: false, italic: true, to: font) : font
        }
        mono = StyleSheet.monoFont(
            family: typography.monoFamily,
            size: StyleSheet.monoPointSize(typography: typography),
            ligatures: typography.monoLigatures
        )
        emphasis = [
            bodyFont,
            StyleSheet.applying(bold: true, italic: false, to: bodyFont),
            StyleSheet.applying(bold: false, italic: true, to: bodyFont),
            StyleSheet.applying(bold: true, italic: true, to: bodyFont),
        ]

        // Metrics.
        //
        // The grid is quantised in half units so the line height can land on an
        // even point.  Rounding it to whole units meant a 16pt body could only
        // ever be led 24pt or 28pt — 1.50 or 1.75 — and 1.50 is tight for a
        // serif running to 70 characters, while 1.75 is loose enough to break
        // the page into stripes.  Half units put 26pt (1.625) in reach, which is
        // the value the measure actually wants.
        let idealLineHeight = typography.bodySize * typography.lineHeightMultiple
        let grid = max(2, (idealLineHeight / 2).rounded() / 2)
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

    /// Whole steps of the modular scale for H1–H4, then compact steps below the
    /// body size for H5–H6. This keeps deep headings distinct without letting
    /// them collapse into indistinguishable body text (§11.1).
    private static let headingExponents: [CGFloat] = [3, 2, 1.25, 0.5, -0.5, -0.75]

    static func headingSize(level: Int, typography: TypographyConfig) -> CGFloat {
        let exponent = headingExponents[clampLevel(level) - 1]
        return typography.bodySize * pow(typography.scaleRatio, exponent)
    }

    /// Vertical rhythm in whole grid units, so a heading never knocks the body
    /// text off the baseline grid (§11.1).
    public func headingSpacing(level: Int) -> (before: CGFloat, after: CGFloat) {
        let before: [CGFloat] = [6, 6, 6, 3, 3, 3]
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

    /// Code sized to sit level with the prose beside it whatever face resolves.
    ///
    /// `monoSizeAdjust`'s default was measured against SF Mono (see its doc
    /// comment), so it only means what it was calibrated to mean for that face.
    /// Menlo, Fira Code and JetBrains Mono disagree with SF Mono by several
    /// percent at the same point size, and the fixed fraction then reads correct
    /// against one and visibly large or small against the next.  Normalising the
    /// resolved face onto SF Mono's x-height keeps the setting's meaning and is a
    /// no-op when the configured face *is* SF Mono — today's calibration stands.
    private static func monoPointSize(typography: TypographyConfig) -> CGFloat {
        let requested = typography.bodySize * typography.monoSizeAdjust
        let resolved = monoFont(family: typography.monoFamily, size: requested, ligatures: true)
        let reference = monoFont(family: "SF Mono", size: requested, ligatures: true)
        guard resolved.xHeight > 0, reference.xHeight > 0 else { return requested }
        let corrected = requested * (reference.xHeight / resolved.xHeight)
        return min(max(corrected, requested * 0.92), requested * 1.08)
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
        case .note: return "text.alignleft"
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

    /// What a mark drawn *on* the accent must be painted in — the tick inside a
    /// ticked checkbox, a glyph on an accent pill.
    ///
    /// It used to be `background` everywhere, which assumes the page is always
    /// the far side of the accent.  A warm light theme has a near-white page
    /// and a mid-value accent, and a white tick on a light accent is the one
    /// state in the app a reader could not see.  Picking whichever of the page
    /// and its text stands further from the accent keeps the mark legible in
    /// every theme without a per-theme token (§11.2).
    public var onAccent: NSColor {
        let distance = { (color: NSColor) in
            abs(StyleSheet.relativeLuminance(color) - StyleSheet.relativeLuminance(accent))
        }
        return distance(background) >= distance(text) ? background : text
    }

    // MARK: - Task checkbox (§8.5, §11.4)
    //
    // The document's ornament and the Tasks panel's control are one checkbox,
    // and they already share their geometry through `RenderMetrics`.  Their
    // *paint* lives here for the same reason: it carries contrast decisions that
    // must not be made twice, and when only the document's was restyled the two
    // disagreed on what "done" looks like.
    //
    // Both states are the same object — one ring at one weight, plus a tinted
    // field and a tick when the task is done.  A checked box used to be a solid
    // accent slab with a knocked-out tick, which made the loudest mark on the
    // page the one thing the reader has already finished with, said "done" twice
    // over the label's own strikethrough, and spent the accent that links and
    // the caret need on a page's worth of completed rows.

    /// Wash behind a completed box.
    public var taskFieldColor: NSColor {
        accent.panelAlpha(taskFieldAlpha, increaseContrast: increaseContrast)
    }

    private var taskFieldAlpha: CGFloat { 0.14 }

    /// The box's outline.  Open, the ring is the whole affordance, so it comes
    /// from secondary text rather than from `rule`: a theme's rule colour is a
    /// hairline meant to disappear (warm dark's is two steps off the page), and a
    /// checkbox nobody can see is a checkbox nobody clicks.
    public func taskRingColor(checked: Bool) -> NSColor {
        checked
            ? accent.panelAlpha(0.55, increaseContrast: increaseContrast)
            : textSecondary.panelAlpha(0.70, increaseContrast: increaseContrast)
    }

    /// The tick: the accent, pulled toward the text colour when the accent
    /// cannot carry a stroke against the page.
    ///
    /// The tick used to sit on an accent slab and be knocked out in `onAccent`,
    /// so only the slab's contrast mattered.  It now sits on the page itself, and
    /// a theme's accent is not guaranteed to stand off it: the System theme
    /// adopts whatever accent the user picked, and macOS Yellow against a white
    /// page is under 2:1 — a ticked box would read as an empty one, which is
    /// worse than loud.  Only a theme that cannot clear the bar pays for it.
    ///
    /// Measured against the field the tick lands on, not against the bare page.
    /// The field is the accent at 14% over the background, so it sits *toward*
    /// the accent and takes contrast the page comparison cannot see: the System
    /// theme, which adopts whatever accent the user picked, measured 4:1 on the
    /// page and 2.99:1 on its own field — passing the check while failing on
    /// screen.  The bar stays at 4:1 rather than the 3:1 a non-text mark owes,
    /// because what reaches the screen is 0.9 of this colour, not all of it.
    /// It is 0.9 rather than a hint because the tick is the only thing that
    /// *states* the task is done.
    public var taskTickColor: NSColor {
        let field = ColorResolver.blend(background, accent, taskFieldAlpha)
        let ratio = StyleSheet.contrastRatio(accent, field)
        let base = ratio < 4 ? ColorResolver.blend(accent, text, 0.5) : accent
        return base.panelAlpha(0.90, increaseContrast: increaseContrast)
    }

    static func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let first = relativeLuminance(a)
        let second = relativeLuminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// WCAG relative luminance, on the sRGB components the resolver already
    /// snapshotted.
    static func relativeLuminance(_ color: NSColor) -> CGFloat {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0.5 }
        let channel = { (value: CGFloat) -> CGFloat in
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(srgb.redComponent)
            + 0.7152 * channel(srgb.greenComponent)
            + 0.0722 * channel(srgb.blueComponent)
    }

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
