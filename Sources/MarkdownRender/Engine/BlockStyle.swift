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

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        self.grid = max(1, styleSheet.baselineGrid)
        self.indentUnit = RenderMetrics.indentUnit(bodySize: styleSheet.bodyFont().pointSize)
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
            task: context.task
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
            return RenderMetrics.snap(f.pointSize * 1.45, grid: grid)
        default:
            break
        }
        let natural = f.ascender - f.descender + f.leading
        let base = max(styleSheet.lineHeight, natural * 1.02)
        return RenderMetrics.snap(base, grid: grid)
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
        // column never scrolls horizontally: wrap unbreakable lines by
        // character instead of clipping them at the measure.
        if case .codeBlock = block.content {
            style.lineBreakMode = .byCharWrapping
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
