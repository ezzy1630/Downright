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
    ///
    /// The document's first block adds its own leading spacing on top of this —
    /// an H1 contributes four grid units — so 56 put the title of a typical
    /// document 80pt below the toolbar while the panel beside it started its
    /// first row at 48.  The page read as having slipped down. 36 lands the
    /// same title around 60pt, which is still unmistakably a margin.
    public static let verticalInset: CGFloat = 36

    /// Lane past the prose measure's trailing edge that a *full-bleed* block —
    /// code, a diagram, a table, display math — is allowed to spill into
    /// (§11.1).
    ///
    /// Prose wants 68–72 characters and code does not: at the reading measure a
    /// fenced block gets barely fifty monospace columns, so ordinary source
    /// wraps on nearly every line.  Widening the measure to suit code would
    /// wreck the prose it surrounds, so the container is widened instead and
    /// prose is held back to the measure by a tail indent.
    ///
    /// **Trailing only.**  A symmetric lane would put code underneath the
    /// marker rail, which sits exactly one `gutterWidth` left of the column.
    /// Extending right instead leaves every block sharing one left edge, so a
    /// wide code block reads as reaching further rather than as sitting in a
    /// different column.
    ///
    /// It is a **constant**, and it has to stay one.  The tail indent that
    /// holds prose at the measure lives in paragraph styles, which are baked
    /// into the storage when the document is decorated; a bleed that tracked
    /// the window would make every resize a full re-decoration and blow the
    /// §12 budget on a drag.  A narrow window shrinks the whole column instead,
    /// which narrows prose with it — which is what a narrow window should do.
    public static let codeBleed: CGFloat = 88

    /// Narrowest prose column worth laying out.  The column floor is this plus
    /// the bleed lane, so prose never collapses to keep the code lane alive.
    public static let minimumProseWidth: CGFloat = 240

    /// Padding inside a code block's tinted band.
    public static let codeInsetX: CGFloat = 22
    /// Bottom chrome (closing fence) height.
    public static let codeInsetY: CGFloat = 14
    /// Real header row for the language chip and copy control (§11.3) — tall
    /// enough that a 17pt badge plus its vertical padding sits fully inside,
    /// never clipped by the band's top edge.
    public static let codeHeaderHeight: CGFloat = 36
    public static let codeRuleWidth: CGFloat = 2
    public static let codeCornerRadius: CGFloat = 10
    /// Columns a tab advances inside a code block.  Four, not the platform's
    /// eight: agents emit four-space indentation, and the two have to agree or a
    /// tab-indented row hangs its wraps off a column its glyphs do not sit on.
    public static let codeTabColumns = 4
    /// Corner of an inline code pill.  Smaller than a fenced block's: the pill
    /// is one line tall, and at the block's radius it reads as a lozenge.
    public static let inlineCodeCornerRadius: CGFloat = 3

    /// Page background above and below a fenced block.
    ///
    /// Vertical air inside a code block lives in its chrome rather than in
    /// paragraph spacing, so the band stays flush with its own content — but
    /// that left *nothing* outside it either, and two fences in a row fused
    /// into one tinted slab with a hairline where the corners failed to meet.
    /// This gap is untinted, so consecutive blocks read as two objects.
    public static let codeBlockGap: CGFloat = 8

    /// §11.3 task-checkbox geometry, shared by the document renderer and the
    /// task panel so one task state looks the same everywhere (§8.5).  The
    /// marker column the paragraph reserves for a checkbox is exactly the box
    /// plus the gap plus the left clearance, so the box can never touch or
    /// cross the text column's left edge.
    public static let taskBoxSide: CGFloat = 20
    public static let taskBoxGap: CGFloat = 11
    public static let taskBoxClearance: CGFloat = 4
    public static var taskMarkerColumn: CGFloat {
        taskBoxSide + taskBoxGap + taskBoxClearance
    }

    /// The box and its tick as ratios of the side, so the panel's 16pt
    /// checkbox is the document's 20pt checkbox at a smaller scale rather than
    /// a second control that happens to look similar (§8.5).
    public static let taskBoxCornerRatio: CGFloat = 5.5 / 20
    public static let taskBoxStrokeRatio: CGFloat = 1.5 / 20
    public static let taskTickStrokeRatio: CGFloat = 2 / 20

    /// The tick, in unit coordinates measured from the bottom-left of the box.
    ///
    /// It is inset from the box rather than spanning it corner to corner.  The
    /// tick this replaced ran from 13% to 89% of the side: at the panel's 16pt
    /// it touched the corner radius on both ends, so the mark read as a
    /// scribble filling a square instead of a check sitting in one.
    public static let taskTick: [CGPoint] = [
        CGPoint(x: 0.245, y: 0.500),
        CGPoint(x: 0.430, y: 0.315),
        CGPoint(x: 0.765, y: 0.690),
    ]

    /// One-line chip a long code block collapses to in Read mode (§5.1).
    public static let chipHeight: CGFloat = 30
    /// Code blocks longer than this collapse in Read mode (§5.1).
    public static let codeCollapseLineCount = 20

    public static let calloutRuleWidth: CGFloat = 3
    public static let calloutInsetX: CGFloat = 16
    public static let calloutIconInsetX: CGFloat = 34
    public static let calloutInsetY: CGFloat = 8
    public static let calloutCornerRadius: CGFloat = 8
    public static let quoteRuleWidth: CGFloat = 2

    public static let tableRowPadding: CGFloat = 6
    public static let tableColumnGap: CGFloat = 18
    public static let tableRuleWidth: CGFloat = 1

    public static let imageCornerRadius: CGFloat = 8
    public static let imageShadowRadius: CGFloat = 10
    public static let imageCaptionGap: CGFloat = 8

    public static let thematicBreakSpace: CGFloat = 26

    /// Indentation applied per level of list or quote nesting.  Markers are in
    /// the gutter, so this is the only thing expressing nesting in the text
    /// column.
    public static func indentUnit(bodySize: CGFloat) -> CGFloat {
        (bodySize * 1.45).rounded()
    }

    /// Snaps a height to the baseline grid so structural-zoom transitions
    /// animate cleanly rather than jittering (§11.1).
    ///
    /// Rounds *up* by default: a row must never be shorter than the glyphs it
    /// carries.  Code passes `.down` deliberately — its line height is a chosen
    /// ratio well clear of the font's own ascent-to-descent, so rounding up
    /// only pushed it further from the ratio.
    public static func snap(
        _ value: CGFloat, grid: CGFloat, rounding: FloatingPointRoundingRule = .up
    ) -> CGFloat {
        guard grid > 0.5 else { return value.rounded() }
        return (value / grid).rounded(rounding) * grid
    }
}
