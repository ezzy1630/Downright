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

    public static let root = BlockContext(listDepth: 0, quoteDepth: 0, calloutKind: nil, ordinal: nil)

    public init(listDepth: Int, quoteDepth: Int, calloutKind: CalloutKind?, ordinal: Int?) {
        self.listDepth = listDepth
        self.quoteDepth = quoteDepth
        self.calloutKind = calloutKind
        self.ordinal = ordinal
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
            quoteDepth: min(context.quoteDepth, 6)
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
        case .blockQuote: return styleSheet.textSecondary
        case .callout(let kind, _): return context.quoteDepth > 0 ? styleSheet.calloutColor(kind) : styleSheet.text
        case .thematicBreak, .frontMatter: return styleSheet.textSecondary
        default: return context.quoteDepth > 0 ? styleSheet.textSecondary : styleSheet.text
        }
    }

    /// Exact, grid-snapped line height.  Fixed per block kind and *independent
    /// of the caret*, which is the invariant that makes §6.1a's "line height
    /// never changes when the caret enters a block" true by construction
    /// rather than by care.
    func lineHeight(for content: BlockContent) -> CGFloat {
        let f = font(for: content)
        let natural = f.ascender - f.descender + f.leading
        let base = max(styleSheet.lineHeight, natural * 1.02)
        return RenderMetrics.snap(base, grid: grid)
    }

    func indent(for content: BlockContent, context: BlockContext) -> CGFloat {
        var levels = CGFloat(context.listDepth + context.quoteDepth)
        if case .codeBlock = content { levels += 0 }
        return levels * indentUnit
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
        case .listItem:
            style.paragraphSpacingBefore = 0
            style.paragraphSpacing = 0
        case .table, .thematicBreak:
            style.paragraphSpacingBefore = 0
            style.paragraphSpacing = 0
        case .callout, .blockQuote:
            style.firstLineHeadIndent = indent + RenderMetrics.calloutInsetX
            style.headIndent = indent + RenderMetrics.calloutInsetX
            style.paragraphSpacingBefore = 0
            style.paragraphSpacing = 0
        default:
            // Paragraphs inside a list are the body of a list item; giving
            // them full inter-paragraph air would space a tight list like a
            // sequence of essays.
            style.paragraphSpacing = RenderMetrics.snap(h * (context.listDepth > 0 ? 0.15 : 0.45), grid: grid)
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
        if case .heading(let level) = block.content { attrs[.drHeading] = level }
        if styleSheet.theme.typography.monoLigatures == false, isMono(block.content) {
            attrs[.ligature] = 0
        }
        attributeCache[k] = attrs
        return attrs
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
