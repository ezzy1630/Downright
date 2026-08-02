import AppKit

/// Geometry constants shared by the engine, the fragments, and the view.
///
/// These are *structure*, not taste — the palette and the type scale live in
/// `StyleSheet` (§11.1, §11.2).  Anything here that a theme should be able to
/// override would be a bug in the theme layer, not a constant to move.
public enum RenderMetrics {
    /// Width of the left rail that block markers live in (§6.1a).  Wide enough
    /// for `- [ ]` and `> [!WARNING]`'s icon at body size, narrow enough that
    /// it never competes with the text column.
    public static let gutterWidth: CGFloat = 44

    /// Slack reserved to the left of the text column so a caret-anchored
    /// reveal (§6.1c) can shift a line *left* without clipping.  A revealed
    /// `**` or `` ` `` pair is a few points wide; 44 covers the worst realistic
    /// case (a revealed reference-style link's `[` plus a wide leading marker).
    public static let revealSlack: CGFloat = 44

    /// Vertical inset at the top and bottom of the text container.
    public static let verticalInset: CGFloat = 56

    /// Padding inside a code block's tinted band.
    public static let codeInsetX: CGFloat = 16
    public static let codeInsetY: CGFloat = 10
    public static let codeRuleWidth: CGFloat = 2
    public static let codeCornerRadius: CGFloat = 6

    /// One-line chip a long code block collapses to in Read mode (§5.1).
    public static let chipHeight: CGFloat = 30
    /// Code blocks longer than this collapse in Read mode (§5.1).
    public static let codeCollapseLineCount = 20

    public static let calloutRuleWidth: CGFloat = 3
    public static let calloutInsetX: CGFloat = 16
    public static let calloutIconInsetX: CGFloat = 34
    public static let quoteRuleWidth: CGFloat = 2

    public static let tableRowPadding: CGFloat = 6
    public static let tableColumnGap: CGFloat = 18
    public static let tableRuleWidth: CGFloat = 1

    public static let imageCornerRadius: CGFloat = 8
    public static let imageShadowRadius: CGFloat = 10
    public static let imageCaptionGap: CGFloat = 8

    public static let thematicBreakSpace: CGFloat = 26

    public static let frontMatterInsetX: CGFloat = 14
    public static let frontMatterInsetY: CGFloat = 10
    public static let frontMatterRowGap: CGFloat = 4

    /// Indentation applied per level of list or quote nesting.  Markers are in
    /// the gutter, so this is the only thing expressing nesting in the text
    /// column.
    public static func indentUnit(bodySize: CGFloat) -> CGFloat {
        (bodySize * 1.45).rounded()
    }

    /// Snaps a height to the baseline grid so structural-zoom transitions
    /// animate cleanly rather than jittering (§11.1).
    public static func snap(_ value: CGFloat, grid: CGFloat) -> CGFloat {
        guard grid > 0.5 else { return value.rounded() }
        return (value / grid).rounded(.up) * grid
    }
}
