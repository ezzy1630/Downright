import AppKit
import MarkdownCore

/// Where a block sits in the tree.  `MDBlock` has no parent pointer (it is a
/// flat, cheap node by design), so the decorator carries the ancestry down as
/// it walks instead of reconstructing it per block.
public struct BlockContext: Hashable, Sendable {
    public var listDepth: Int
    public var quoteDepth: Int
    public var calloutKind: CalloutKind?
    /// Ordinal of the enclosing ordered list item, for the gutter marker.
    public var ordinal: Int?
    /// True while inside a `- [ ]` task item, so a task's text (which lives in
    /// a child paragraph block) reserves the checkbox column, not the bullet
    /// column (§11.3).
    public var task: Bool

    public static let root = BlockContext(listDepth: 0, quoteDepth: 0, calloutKind: nil, ordinal: nil, task: false)

    public init(listDepth: Int, quoteDepth: Int, calloutKind: CalloutKind?, ordinal: Int?, task: Bool) {
        self.listDepth = listDepth
        self.quoteDepth = quoteDepth
        self.calloutKind = calloutKind
        self.ordinal = ordinal
        self.task = task
    }
}

/// Resolving one base writing direction for a whole document.
enum WritingDirection {
    /// Ranges whose letters are strongly right-to-left.  All are in the BMP,
    /// so a scalar comparison covers them without a bidi table.
    private static func isRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x05FF,  // Hebrew
             0x0600...0x06FF,  // Arabic
             0x0700...0x074F,  // Syriac
             0x0750...0x077F,  // Arabic Supplement
             0x0780...0x07BF,  // Thaana
             0x07C0...0x08FF,  // NKo, Samaritan, Mandaic, Arabic Extended-A
             0xFB1D...0xFDFF,  // Hebrew and Arabic presentation forms
             0xFE70...0xFEFF:  // Arabic presentation forms B
            return true
        default:
            return false
        }
    }

    /// The direction of the document's first strong letter — the same rule
    /// HTML's `dir=auto` uses.
    ///
    /// Only *letters* vote.  A markdown document opens on `#`, `-`, or a digit
    /// far more often than on a word, and punctuation is directionally neutral,
    /// so classifying on the first non-space character would decide nothing and
    /// decide it loudly.
    ///
    /// The scan is bounded because it runs on the decoration path: a document's
    /// direction is settled by its opening sentence, and reading further would
    /// cost keystroke latency to learn nothing.
    static func of(_ text: String, limit: Int = 1024) -> NSWritingDirection {
        for scalar in text.unicodeScalars.prefix(limit) {
            if isRightToLeft(scalar) { return .rightToLeft }
            if CharacterSet.letters.contains(scalar) { return .leftToRight }
        }
        return .leftToRight
    }
}

/// Fonts, colours, and paragraph styles per block kind.
///
/// Everything here is memoised: a 5k-line document is a few dozen distinct
/// styles repeated thousands of times, and `NSParagraphStyle` allocation shows
/// up immediately in the keystroke budget (§12) if it is not shared.
final class BlockStyleFactory {
    let styleSheet: StyleSheet
    private var paragraphCache: [StyleKey: NSParagraphStyle] = [:]
    private var attributeCache: [StyleKey: [NSAttributedString.Key: Any]] = [:]
    private let grid: CGFloat
    private let indentUnit: CGFloat
    /// How far a wrapped code row hangs past its statement's own left edge.
    /// Two monospace columns: enough to read as a continuation at a glance,
    /// small enough that it is never mistaken for a level of nesting.
    private let codeContinuationIndent: CGFloat

    /// Base writing direction for every block, resolved once for the whole
    /// document (see `WritingDirection.of`).
    ///
    /// It has to be one decision for the document, not `.natural` per
    /// paragraph.  `.natural` asks each paragraph to resolve its own direction
    /// from its own first strong character, so a single Hebrew or Arabic bullet
    /// in an English list became right-aligned on its own — flung to the far
    /// margin with its bullet on the opposite side, while its siblings stayed
    /// left.  The list stopped having a left edge.
    ///
    /// A browser does not do this: `direction` inherits from the container, so
    /// every `<li>` in a list shares one direction and only the *runs* inside a
    /// line get bidi-reordered.  That is the correct model and this matches it.
    var baseWritingDirection: NSWritingDirection = .leftToRight {
        didSet {
            guard baseWritingDirection != oldValue else { return }
            paragraphCache.removeAll(keepingCapacity: true)
        }
    }

    /// Width of one monospace column, which is what a code row's own
    /// indentation is measured in.
    private let monoAdvance: CGFloat
    private var codeRowCache: [CodeRowKey: NSParagraphStyle] = [:]

    private struct CodeRowKey: Hashable {
        var columns: Int
        var head: CGFloat
    }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        self.grid = max(1, styleSheet.baselineGrid)
        self.indentUnit = RenderMetrics.indentUnit(bodySize: styleSheet.bodyFont().pointSize)
        let mono = styleSheet.monoFont()
        let advance = NSAttributedString(string: "MM", attributes: [.font: mono]).size().width
        self.codeContinuationIndent = (advance > 1 ? advance : mono.pointSize).rounded()
        self.monoAdvance = advance > 1 ? advance / 2 : mono.pointSize / 2
    }

    /// Columns a code row's leading whitespace occupies, tabs snapping to the
    /// four-column stops the code paragraph style installs.
    static func indentColumns(of line: NSString) -> Int {
        var columns = 0
        var index = 0
        while index < line.length {
            switch line.character(at: index) {
            case 0x20: columns += 1
            case 0x09: columns += RenderMetrics.codeTabColumns - (columns % RenderMetrics.codeTabColumns)
            default: return columns
            }
            index += 1
        }
        return columns
    }

    /// The paragraph style for one physical row of a code block, hung off that
    /// row's *own* indentation.
    ///
    /// Rows in a code block do not share a wrap indent.  A row indented four
    /// columns has to wrap past those four columns; sharing the block's single
    /// `headIndent` put the continuation of a nested statement to the left of
    /// the statement itself, which reads as a new line of source rather than as
    /// the same one carrying on.
    func codeRowStyle(base: NSParagraphStyle, indentColumns columns: Int) -> NSParagraphStyle {
        let key = CodeRowKey(columns: columns, head: base.firstLineHeadIndent)
        if let cached = codeRowCache[key] { return cached }
        guard let style = base.mutableCopy() as? NSMutableParagraphStyle else { return base }
        style.headIndent = base.firstLineHeadIndent
            + CGFloat(columns) * monoAdvance
            + codeContinuationIndent
        let frozen = style.copy() as? NSParagraphStyle ?? base
        codeRowCache[key] = frozen
        return frozen
    }

    struct StyleKey: Hashable {
        var kind: Int
        var level: Int
        var listDepth: Int
        var quoteDepth: Int
        var ordinalDigits: Int
        /// A task's text reserves the checkbox column, a bullet's does not
        /// (§11.3).  Two rows at the same depth must never share a cache entry
        /// or whichever decorates first locks the other into its column.
        var task: Bool
        /// A callout reserves a wider column than the plain quote it is built
        /// from, so `indent(for:context:)` returns a different value for the
        /// two.  Without this the paragraph inside `> [!NOTE]` and the one
        /// inside a bare `>` share an entry, and whichever the decorator
        /// reaches first locks the other into its indent.
        var callout: Bool
    }

    /// Stable discriminator per block kind, so the cache never confuses a
    /// heading with a table.
    static func kindCode(_ content: BlockContent) -> Int {
        switch content {
        case .document: return 0
        case .heading: return 1
        case .paragraph: return 2
        case .blockQuote: return 3
        case .callout: return 4
        case .list: return 5
        case .listItem: return 6
        case .codeBlock: return 7
        case .mermaid: return 8
        case .mathBlock: return 9
        case .table: return 10
        case .thematicBreak: return 11
        case .htmlBlock: return 12
        case .frontMatter: return 13
        case .footnoteDefinition: return 14
        }
    }

    private static func level(_ content: BlockContent) -> Int {
        if case .heading(let l) = content { return l }
        return 0
    }

    func key(for block: MDBlock, context: BlockContext) -> StyleKey {
        StyleKey(
            kind: Self.kindCode(block.content),
            level: Self.level(block.content),
            listDepth: min(context.listDepth, 8),
            quoteDepth: min(context.quoteDepth, 6),
            ordinalDigits: context.ordinal.map { max(1, String(abs($0)).count) } ?? 0,
            task: context.task,
            callout: context.calloutKind != nil
        )
    }

    func font(for content: BlockContent) -> NSFont {
        switch content {
        case .heading(let level): return styleSheet.headingFont(level: level)
        case .codeBlock, .mermaid, .mathBlock: return styleSheet.monoFont()
        case .frontMatter: return styleSheet.monoFont(size: styleSheet.bodyFont().pointSize * 0.9)
        default: return styleSheet.bodyFont()
        }
    }

    private func color(for content: BlockContent, context: BlockContext) -> NSColor {
        switch content {
        case .heading(let level): return styleSheet.headingColor(level: level)
        case .blockQuote: return styleSheet.text
        case .callout(let kind, _): return context.quoteDepth > 0 ? styleSheet.calloutColor(kind) : styleSheet.text
        case .thematicBreak, .frontMatter: return styleSheet.textSecondary
        default: return styleSheet.text
        }
    }

    /// Exact, grid-snapped line height.  Fixed per block kind and *independent
    /// of the caret*, which is the invariant that makes §6.1a's "line height
    /// never changes when the caret enters a block" true by construction
    /// rather than by care.
    func lineHeight(for content: BlockContent) -> CGFloat {
        let f = font(for: content)
        switch content {
        case .codeBlock, .mermaid:
            // Code wants a *tighter* leading than prose, not a looser one: a
            // block of source is scanned down the left edge, and air between
            // rows works against that.  Snapping 1.45 *up* to the prose grid
            // put a 14.7pt face on 24pt rows — 1.63, airier than the body text
            // it sits inside.
            //
            // The grid still has to be honoured, or a ten-line block pushes
            // everything after it off the baseline (§11.1); half a grid unit
            // is the finest step that keeps whole blocks landing back on it.
            // Rounding to nearest picks whichever step sits closest to 1.35
            // rather than always erring one way.
            let ideal = f.pointSize * 1.35
            let snapped = RenderMetrics.snap(
                ideal, grid: max(1, grid / 2), rounding: .toNearestOrAwayFromZero
            )
            // Never below the glyphs' own extent, however coarse the grid.
            return max(snapped, RenderMetrics.snap(
                f.ascender - f.descender, grid: max(1, grid / 2)
            ))
        default:
            break
        }
        let natural = f.ascender - f.descender + f.leading
        let base = max(styleSheet.lineHeight, natural * 1.02)
        return RenderMetrics.snap(base, grid: grid)
    }

    /// Blocks that may use the bleed lane past the prose measure's trailing
    /// edge (`RenderMetrics.codeBleed`).
    ///
    /// These are the blocks whose content has its own natural width and reads
    /// worse when squeezed into a reading measure: source, diagrams, tables,
    /// display math.  Everything else — prose, lists, quotes, callouts, images,
    /// front matter — is inset back to the measure so the reading column keeps
    /// its 68–72 characters.
    static func isFullBleed(_ content: BlockContent) -> Bool {
        switch content {
        case .codeBlock, .mermaid, .table, .mathBlock: return true
        default: return false
        }
    }

    func indent(for content: BlockContent, context: BlockContext) -> CGFloat {
        // The first list level needs only its ornament column. Additional
        // levels earn one structural indent each; charging the top-level item
        // for both made task text drift far right of surrounding prose.
        var levels = CGFloat(max(0, context.listDepth - 1) + context.quoteDepth)
        if case .codeBlock = content { levels += 0 }
        var result = levels * indentUnit
        if context.calloutKind != nil {
            // A callout consumes one quote level, but its semantic icon needs
            // a wider column than a plain quote rule. Replace that level's
            // ordinary indent instead of stacking both values.
            result += RenderMetrics.calloutIconInsetX - indentUnit
        }
        // A fenced block inside a list item sits at the item's content edge —
        // the marker column — not at the structural indent, which skips the
        // first level entirely.  Without this the nested block's band and text
        // collide with the list marker lane (§11.3).
        if case .codeBlock = content, context.listDepth > 0 {
            result += markerColumn(context: context, task: false)
        }
        return result
    }

    func paragraphStyle(for block: MDBlock, context: BlockContext) -> NSParagraphStyle {
        let k = key(for: block, context: context)
        if let cached = paragraphCache[k] { return cached }

        let style = NSMutableParagraphStyle()
        let h = lineHeight(for: block.content)
        style.minimumLineHeight = h
        style.maximumLineHeight = h
        style.lineSpacing = 0
        style.lineBreakMode = .byWordWrapping
        style.alignment = .natural
        // One direction for the document, so a list keeps a single edge and the
        // head indents below mean the same thing on every line.
        style.baseWritingDirection = baseWritingDirection

        // The text container is the prose measure *plus* a trailing bleed lane.
        // Prose is held back off it so the reading column keeps its 68–72
        // characters; a full-bleed block leaves the tail alone and so gets the
        // extra width (§11.1).  Every block still shares one left edge.  The
        // value is a constant, so a window resize stays a relayout and never
        // becomes a re-decoration.
        if !Self.isFullBleed(block.content) {
            style.tailIndent = -RenderMetrics.codeBleed
        }

        let indent = self.indent(for: block.content, context: context)
        style.firstLineHeadIndent = indent
        style.headIndent = indent

        switch block.content {
        case .heading(let level):
            let spacing = styleSheet.headingSpacing(level: level)
            style.paragraphSpacingBefore = RenderMetrics.snap(spacing.before, grid: grid)
            style.paragraphSpacing = RenderMetrics.snap(spacing.after, grid: grid)
        case .codeBlock, .mermaid, .mathBlock, .frontMatter:
            // Vertical air around these lives in the fragment's chrome, not in
            // paragraph spacing, so the tinted band is flush with its content.
            style.paragraphSpacingBefore = 0
            style.paragraphSpacing = 0
            style.firstLineHeadIndent = indent + RenderMetrics.codeInsetX
            style.headIndent = indent + RenderMetrics.codeInsetX
        case .listItem(_, let checkbox):
            style.paragraphSpacingBefore = 0
            // Task rows are controls, not compressed prose. One grid unit
            // separates their hit targets and makes nested groups scannable.
            style.paragraphSpacing = checkbox == nil ? 0 : grid
            if context.listDepth > 0 {
                // The semantic ornament is drawn in the hanging column by
                // `ListOrnamentFragment`; the source marker is not inline.
                // Both the first visual line and every wrap therefore start
                // at the same content edge.  A split indent here makes list
                // text visibly staircase after the first line and places the
                // checkbox on top of the first word.
                //
                // A task reserves the full checkbox column (§11.3): the box,
                // the gap to the label, and 4pt of left clearance.  Anything
                // narrower leaves the box overlapping the fragment origin,
                // which is exactly the clipped-checkbox defect.
                let contentEdge = indent + markerColumn(context: context, task: checkbox != nil)
                style.firstLineHeadIndent = contentEdge
                style.headIndent = contentEdge
            }
        case .table, .thematicBreak:
            style.paragraphSpacingBefore = 0
            style.paragraphSpacing = 0
        case .callout:
            // The block marker owns the paragraph's effective style. Reserve
            // the icon column here even before child content overrides run.
            let inset = RenderMetrics.calloutIconInsetX
            style.firstLineHeadIndent = indent + inset
            style.headIndent = indent + inset
            style.paragraphSpacingBefore = 0
            style.paragraphSpacing = 0
        case .blockQuote:
            let inset = RenderMetrics.calloutInsetX
            style.firstLineHeadIndent = indent + inset
            style.headIndent = indent + inset
            style.paragraphSpacingBefore = 0
            style.paragraphSpacing = 0
        default:
            // Paragraphs inside a list are the body of a list item; giving
            // them full inter-paragraph air would space a tight list like a
            // sequence of essays.
            style.paragraphSpacing = RenderMetrics.snap(h * (context.listDepth > 0 ? 0.15 : 0.45), grid: grid)
            if context.listDepth > 0 {
                let contentEdge = indent + markerColumn(context: context, task: context.task)
                style.firstLineHeadIndent = contentEdge
                style.headIndent = contentEdge
            }
        }

        // Code is the one block that keeps its glyphs in Read mode, and the
        // column never scrolls horizontally, so long lines have to wrap
        // somewhere.  Not mid-token, though: `.byCharWrapping` cut
        // `ParsedDocument` into `Pars` / `edDocument` and `caret:` into `car` /
        // `et:`, which is harder to read than the overflow it was avoiding.
        // Word wrapping breaks at the syntactic gaps code already has and
        // still falls back to character breaking for a token longer than the
        // whole line, so nothing is clipped.
        //
        // The continuation indent is what makes the result legible as code: a
        // wrapped row starts inside its own statement instead of impersonating
        // a new line of source.  The closing tail inset keeps the last glyph
        // off the band's right edge, mirroring `codeInsetX` on the left.
        if case .codeBlock = block.content {
            style.lineBreakMode = .byWordWrapping
            style.headIndent = style.firstLineHeadIndent + codeContinuationIndent
            style.tailIndent = -RenderMetrics.codeInsetX
            // Deterministic tab stops, so the column a tab lands on is the same
            // one `indentColumns(of:)` counts when it measures a row's hang.
            style.tabStops = []
            style.defaultTabInterval = CGFloat(RenderMetrics.codeTabColumns) * monoAdvance
        }

        let frozen = style.copy() as? NSParagraphStyle ?? NSParagraphStyle.default
        paragraphCache[k] = frozen
        return frozen
    }

    /// Attributes every character of the block starts from.  Inline spans and
    /// markers layer on top with `addAttributes`.
    func baseAttributes(for block: MDBlock, context: BlockContext) -> [NSAttributedString.Key: Any] {
        let k = key(for: block, context: context)
        if let cached = attributeCache[k] { return cached }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font(for: block.content),
            .foregroundColor: color(for: block.content, context: context),
            .paragraphStyle: paragraphStyle(for: block, context: context),
        ]
        if case .heading(let level) = block.content {
            attrs[.drHeading] = level
            let pointSize = font(for: block.content).pointSize
            if pointSize > 28 { attrs[.kern] = pointSize * -0.022 }
            else if pointSize >= 20 { attrs[.kern] = pointSize * -0.014 }
            else if level == 5 { attrs[.kern] = pointSize * 0.04 }
            else if level == 6 { attrs[.kern] = pointSize * 0.06 }
        }
        if styleSheet.theme.typography.monoLigatures == false, isMono(block.content) {
            attrs[.ligature] = 0
        }
        attributeCache[k] = attrs
        return attrs
    }

    /// Width reserved for the visual list ornament plus a half-em gap. The
    /// source marker is hidden, so wrapped lines must start at this text edge,
    /// not at the ornament's left edge.  A task checkbox reserves its own
    /// dedicated column (§11.3) rather than sharing the bullet column.
    private func markerColumn(context: BlockContext, task: Bool) -> CGFloat {
        if task { return RenderMetrics.taskMarkerColumn }
        let bodySize = styleSheet.bodyFont().pointSize
        let gap = bodySize * 0.5
        guard let ordinal = context.ordinal else {
            return max(bodySize * 1.1, bodySize * 0.625 + gap)
        }
        let digits = max(1, String(abs(ordinal)).count)
        let font = NSFont.monospacedDigitSystemFont(ofSize: bodySize * 0.92, weight: .regular)
        let marker = NSAttributedString(
            string: String(repeating: "8", count: digits) + ".",
            attributes: [.font: font]
        )
        return marker.size().width + gap
    }

    private func isMono(_ content: BlockContent) -> Bool {
        switch content {
        case .codeBlock, .mermaid, .mathBlock, .frontMatter: return true
        default: return false
        }
    }

    /// Marker styling: dimmed, same metrics as the text it sits in, so showing
    /// or hiding one changes nothing but the horizontal run (§6.1).
    func markerAttributes(dimmed: Bool) -> [NSAttributedString.Key: Any] {
        [
            .drMarker: true,
            .foregroundColor: dimmed ? styleSheet.marker : styleSheet.textSecondary,
        ]
    }
}
